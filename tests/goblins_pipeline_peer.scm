;;; Test-only Guile adapter.  Goblins itself remains unmodified.
(sigaction SIGPIPE SIG_IGN)

(use-modules (goblins)
             (goblins utils hashmap)
             (goblins actor-lib io)
             (goblins actor-lib on)
             (goblins ocapn ids)
             (goblins ocapn captp)
             (goblins ocapn netlayer base-port)
             (goblins vat)
             (fibers conditions)
             (ice-9 match)
             (ice-9 iconv))

(define locator-file (getenv "GOBLINS_OCAPN_PEER_LOCATOR"))
(define reverse-mode (equal? (getenv "GOBLINS_PIPELINE_MODE") "reverse"))
(define reverse-scenario (or (getenv "GOBLINS_REVERSE_SCENARIO") "success"))
(define provider-swiss
  (string->bytevector "pipeline-provider-test-swiss" "ascii"))

;; The adapter uses the same small TCP testing netlayer shape as the pinned
;; upstream fixture.  It contains no CapTP implementation.
(define (use-nonblocking-i/o port)
  (fcntl port F_SETFL (logior O_NONBLOCK (fcntl port F_GETFL))))

(define (make-server-socket+port port max-connections)
  (let ((sock (socket AF_INET SOCK_STREAM IPPROTO_TCP)))
    (bind sock AF_INET INADDR_ANY (or port 0))
    (setsockopt sock SOL_SOCKET SO_REUSEADDR 1)
    (fcntl sock F_SETFD FD_CLOEXEC)
    (use-nonblocking-i/o sock)
    (listen sock max-connections)
    (values sock (vector-ref (getsockname sock) 2))))

(define (make-client-socket host port)
  (match (getaddrinfo host (number->string port)
                      AI_NUMERICSERV AF_INET SOCK_STREAM IPPROTO_TCP)
    ((info _ ...)
     (let* ((sock (socket AF_INET SOCK_STREAM IPPROTO_TCP))
            (address (sockaddr:addr (addrinfo:addr info))))
       (use-nonblocking-i/o sock)
       (connect sock AF_INET address port)
       sock))))

(define-actor (^pipeline-netlayer bcom host #:optional [port 0])
  (define-values (sock assigned-port)
    (make-server-socket+port port 32))
  (define socket-io (spawn ^io sock #:cleanup close-port))
  (define our-location
    (make-ocapn-peer 'tcp-testing-only "guile-pipeline"
                     (hashmap ("host" host)
                              ("port" (number->string assigned-port)))))
  (define (incoming-accept)
    (on-match (<- socket-io (lambda (resource) (accept resource O_NONBLOCK)))
      ((client-socket . _)
       (setvbuf client-socket 'block)
       (use-nonblocking-i/o client-socket)
       client-socket)))
  (define (outgoing-connect-to-loc loc)
    (unless (eq? (ocapn-peer-transport loc) 'tcp-testing-only)
      (error "wrong test netlayer"))
    (let* ((hints (ocapn-peer-hints loc))
           (host (hashmap-ref hints "host"))
           (port (hashmap-ref hints "port")))
      (make-client-socket host (string->number port))))
  (^base-port-netlayer bcom our-location incoming-accept
                       outgoing-connect-to-loc))

(define (^echo _bcom)
  (lambda args
    (if reverse-mode "nim-reverse-pipeline-ok" "goblins-pipeline-ok")))

(define (^promise-provider _bcom vow resolver echo)
  (lambda ()
    (<-np resolver 'fulfill echo)
    vow))

(define vat (spawn-vat #:name "pipeline-driver"))
(define done (make-condition))

(with-vat vat
  (define netlayer (spawn ^pipeline-netlayer "localhost"))
  (define mycapn (spawn-mycapn netlayer))
  (if reverse-mode
      (let* ((locator (getenv "NIM_OCAPN_PIPELINE_LOCATOR"))
             (provider-sref (string->ocapn-id locator)))
        ;; Keep this file as a readiness marker for the shared Python harness.
        (when locator-file
          (call-with-output-file locator-file
            (lambda (port) (display "reverse-driver-ready" port))))
        (on (<- mycapn 'enliven provider-sref)
            (lambda (provider)
              (format #t "reverse: provider-ready~%")
              (force-output)
              (define pending (<- provider 'make-promise))
              (format #t "reverse: promise-requested~%")
              (force-output)
              ;; These sends are queued before the resolver call below.  The
              ;; Nim trace sink records the wire-level op:deliver ordering.
              (define (report value)
                (set! completed (1+ completed))
                (when (>= completed expected)
                  (if (equal? value "nim-reverse-pipeline-ok")
                      (format #t "goblins-reverse-pipeline: PASS~%")
                      (format #t "goblins-reverse-pipeline: FAIL value=~s~%" value))
                  (force-output)
                  (signal-condition! done)))
              (define (report-error error)
                (if (equal? reverse-scenario "reject")
                    (format #t "goblins-reverse-pipeline: REJECTED PASS~%")
                    (format #t "goblins-reverse-pipeline: FAIL error=~s~%" error))
                (force-output)
                (signal-condition! done))
              (define expected (if (member reverse-scenario '("repeated" "concurrent")) 2 1))
              (define completed 0)
              (define pipelined (<- pending 'ping))
              (format #t "reverse: pipeline-sent~%")
              (force-output)
              (on pipelined report #:catch report-error)
              (when (member reverse-scenario '("repeated" "concurrent"))
                (let ((second (<- pending 'ping)))
                  (format #t "reverse: second-pipeline-sent~%")
                  (force-output)
                  (on second report #:catch report-error))))))
      (let ()
        (define echo (spawn ^echo))
        (define-values (vow resolver) (spawn-promise-and-resolver))
        (define provider (spawn ^promise-provider vow resolver echo))
        (define registry ($ mycapn 'get-registry))
        ($ registry 'register provider provider-swiss)
        (on (<- netlayer 'our-location)
            (lambda (loc)
              (when locator-file
                (call-with-output-file locator-file
                  (lambda (port) (display (ocapn-id->string loc) port)))))))))

(wait done)
