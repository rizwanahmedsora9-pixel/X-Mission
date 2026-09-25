/* Tiny forking HTTP listener for the RNS Magisk module.
 * It does not parse HTTP. It accepts a TCP connection, records the peer
 * address, and execs the shell handler with the socket on stdin/stdout.
 * Bind address is 0.0.0.0 so a preview proxy and LAN clients can connect.
 *
 * Usage: rns-httpd PORT HANDLER
 *        rns-httpd --check
 *
 * HANDLER is executed as: $RNS_BB sh HANDLER   if RNS_BB is set
 *                         /bin/sh HANDLER      otherwise
 * The child inherits CLIENT_IP and CLIENT_PORT.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_KIDS 48
#define CHILD_TTL 25

struct kid {
    pid_t pid;
    time_t born;
};

static struct kid kids[MAX_KIDS];

static void reap(int sig) {
    int status;
    (void)sig;
    while (waitpid(-1, &status, WNOHANG) > 0) {
    }
}

static void track(pid_t pid) {
    int i;
    time_t now = time(NULL);
    for (i = 0; i < MAX_KIDS; i++) {
        if (kids[i].pid > 0) {
            if (kill(kids[i].pid, 0) != 0) {
                kids[i].pid = 0;
            } else if (now - kids[i].born > CHILD_TTL) {
                kill(kids[i].pid, SIGKILL);
                kids[i].pid = 0;
            }
        }
    }
    for (i = 0; i < MAX_KIDS; i++) {
        if (kids[i].pid == 0) {
            kids[i].pid = pid;
            kids[i].born = now;
            return;
        }
    }
    /* Table full: drop the new child rather than pile up. */
    kill(pid, SIGKILL);
}

int main(int argc, char **argv) {
    int port, srv, one = 1;
    char *handler, *bb;
    struct sockaddr_in addr;

    if (argc >= 2 && strcmp(argv[1], "--check") == 0) {
        printf("ok\n");
        return 0;
    }
    if (argc < 3) {
        fprintf(stderr, "usage: rns-httpd PORT HANDLER\n");
        return 2;
    }
    port = atoi(argv[1]);
    handler = argv[2];
    if (port < 1 || port > 65535) {
        fprintf(stderr, "bad port\n");
        return 2;
    }

    signal(SIGCHLD, reap);
    signal(SIGPIPE, SIG_IGN);

    srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) {
        perror("socket");
        return 1;
    }
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((unsigned short)port);
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }
    if (listen(srv, 16) < 0) {
        perror("listen");
        return 1;
    }

    for (;;) {
        struct sockaddr_in peer;
        socklen_t pl = sizeof(peer);
        int c = accept(srv, (struct sockaddr *)&peer, &pl);
        pid_t pid;
        if (c < 0) {
            if (errno == EINTR) continue;
            continue;
        }
        pid = fork();
        if (pid < 0) {
            close(c);
            continue;
        }
        if (pid == 0) {
            char ip[64], pbuf[16];
            if (peer.sin_family == AF_INET) {
                inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof(ip));
                snprintf(pbuf, sizeof(pbuf), "%u", (unsigned)ntohs(peer.sin_port));
            } else {
                snprintf(ip, sizeof(ip), "0.0.0.0");
                snprintf(pbuf, sizeof(pbuf), "0");
            }
            setenv("CLIENT_IP", ip, 1);
            setenv("CLIENT_PORT", pbuf, 1);
            if (dup2(c, 0) < 0 || dup2(c, 1) < 0) _exit(126);
            if (c > 1) close(c);
            close(srv);
            bb = getenv("RNS_BB");
            if (bb && bb[0]) {
                execl(bb, "busybox", "sh", handler, (char *)NULL);
            }
            execl("/bin/sh", "sh", handler, (char *)NULL);
            execl("/system/bin/sh", "sh", handler, (char *)NULL);
            _exit(127);
        }
        close(c);
        track(pid);
    }
}
