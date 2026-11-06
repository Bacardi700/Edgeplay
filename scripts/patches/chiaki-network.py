#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Network tuning for chiaki-ng's streaming socket on Apple platforms.

- SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_VI: iOS marks the stream as interactive
  video, so Wi-Fi sends it in the WMM "video" queue, ahead of downloads and
  background traffic on your network.
- DSCP AF41 (interactive video) on IPv4/IPv6, for routers that honour QoS marks.
- A 2 MB kernel receive buffer (chiaki asks for 100 KB). At 20-30 Mb/s a keyframe
  burst can overflow the small buffer and show up as packet loss and smearing.

Idempotent: running it twice changes nothing. Fails loudly if chiaki's code moved.
usage: chiaki-network.py <chiaki-ng source dir>
"""
import pathlib
import sys

src = pathlib.Path(sys.argv[1]) / "lib" / "src" / "takion.c"
code = src.read_text()
MARK = "/* edgeplay-network-tuning */"
if MARK in code:
    print("takion.c already patched")
    sys.exit(0)

helper = MARK + r'''
#if defined(__APPLE__)
#include <netinet/in.h>
#include <sys/socket.h>
static void edgeplay_tune_socket(chiaki_socket_t sock, int family, ChiakiLog *log)
{
	int svc = NET_SERVICE_TYPE_VI;
	if(setsockopt(sock, SOL_SOCKET, SO_NET_SERVICE_TYPE, &svc, sizeof(svc)) < 0)
		CHIAKI_LOGW(log, "EdgePlay: SO_NET_SERVICE_TYPE failed");
	int dscp = 34 << 2; /* AF41 */
	if(family == AF_INET6)
		setsockopt(sock, IPPROTO_IPV6, IPV6_TCLASS, &dscp, sizeof(dscp));
	else
		setsockopt(sock, IPPROTO_IP, IP_TOS, &dscp, sizeof(dscp));
	int rcvbuf = 2 * 1024 * 1024;
	if(setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf)) < 0)
		CHIAKI_LOGW(log, "EdgePlay: enlarging SO_RCVBUF failed");
	else
		CHIAKI_LOGI(log, "EdgePlay: socket tuned (interactive video, AF41, 2 MB buffer)");
}
#endif
'''

anchor_top = "#define TAKION_A_RWND 0x19000\n"
anchor_call = '''		if(info->ip_dontfrag)
'''
# Insert the call right after chiaki's own SO_RCVBUF in the normal (non-PSN) socket path,
# i.e. the first "if(info->ip_dontfrag)" that follows "takion->sock = socket(".
sock_at = code.find("takion->sock = socket(info->sa->sa_family, SOCK_DGRAM, IPPROTO_UDP);")
call_at = code.find(anchor_call, sock_at)
if anchor_top not in code or sock_at < 0 or call_at < 0:
    sys.exit("chiaki-network.py: anchors not found in takion.c; chiaki-ng changed, update the patch")

call = '''#if defined(__APPLE__)
		edgeplay_tune_socket(takion->sock, info->sa->sa_family, takion->log);
#endif
'''
code = code[:call_at] + call + code[call_at:]
code = code.replace(anchor_top, anchor_top + helper, 1)
src.write_text(code)
print("takion.c patched for network tuning")
