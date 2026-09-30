;;;; src/tools/memory-search.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: search Claude Code memory pages by term.

(defpackage #:dsmr-mcp/src/tools/memory-search
  (:use #:cl)
  (:export #:memory-search-tool))

(in-package #:dsmr-mcp/src/tools/memory-search)
