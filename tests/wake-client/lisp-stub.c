/* SPDX-License-Identifier: AGPL-3.0-or-later */
/*
 * Stand-in for dsmr-bus-watch-lisp in the wake client's case scripts.
 * Prints `argv0=<argv[0]>`, then each argument on its own line, and exits 7.
 */

#include <stdio.h>

int main(int argc, char **argv) {
    printf("argv0=%s\n", argv[0]);
    for (int i = 1; i < argc; i++)
        printf("%s\n", argv[i]);
    return 7;
}
