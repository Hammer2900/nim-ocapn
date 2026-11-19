;;; A small process wrapper around the pinned, unmodified Goblins OCapN
;;; fixture.  The TCP testing fixture writes to sockets which may have been
;;; closed by a short-lived interoperability client; ignoring SIGPIPE lets
;;; Goblins report that socket failure through its normal connection cleanup
;;; instead of terminating the whole peer process.

(sigaction SIGPIPE SIG_IGN)

(let ((fixture (getenv "GOBLINS_UPSTREAM_FIXTURE")))
  (unless (and fixture (file-exists? fixture))
    (error "GOBLINS_UPSTREAM_FIXTURE must name the pinned Goblins fixture"))
  (load fixture))
