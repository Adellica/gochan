;; gochan.scm -- thread-safe channel (FIFO) library based on the go
;; programming language's channel API.
;;
;; Copyright (c) 2017 Kristian Lein-Mathisen.  All rights reserved.
;; License: BSD
(use srfi-18
     (only matchable match)
     (only data-structures list->queue queue->list
           queue-add! queue-empty? queue-remove! queue-first queue-length))

;; todo:
;;
;; - closing a channel
;; - buffers
;; - timeouts

(define (info . args) (void))
(define (info . args) (apply print (cons (current-thread) (cons " " args))))

;; multiple receives
;; multiple sends
;; multiple receive/send simultaniously
;; buffering
;; timeouts (as channels)

;; for me, it helps to think about semaphore as return-values that can
;; block. each gochan-select will create a semaphore and wait for
;; somebody to signal it (sometimes immediately (without waiting),
;; sometimes externally (having to wait)).
(define-record-type gosem
  (make-gosem mutex cv data meta ok)
  gosem?
  (mutex gosem-mutex)
  (cv    gosem-cv)
  (data  gosem-data gosem-data-set!)
  (meta  gosem-meta gosem-meta-set!)
  (ok    gosem-ok   gosem-ok-set!))

(define (make-semaphore)
  (make-gosem (make-mutex)
              (make-condition-variable)
              #f
              #f
              #t))

(define (%gosem-open? sem) (eq? #f (gosem-meta sem)))

;; returns #t on successful signal, #f if semaphore was already
;; signalled.
(define (semaphore-signal! sem data meta ok)
  (info "signalling " sem " from " meta " with data " data (if ok "" " (closed)"))
  (mutex-lock! (gosem-mutex sem))
  (cond ((%gosem-open? sem) ;; available!
         (gosem-data-set! sem data)
         (gosem-meta-set! sem meta)
         (gosem-ok-set! sem ok)
         (condition-variable-signal! (gosem-cv sem))
         (mutex-unlock! (gosem-mutex sem))
         #t)
        (else ;; already signalled
         (mutex-unlock! (gosem-mutex sem))
         #f)))

(define-record-type gochan
  (make-gochan mutex receivers senders)
  gochan?
  (mutex     gochan-mutex)
  (receivers gochan-receivers)
  (senders   gochan-senders))

(define (gochan cap)
  (make-gochan (make-mutex)
               (list->queue '())
               (list->queue '())))

(define (make-send-subscription sem data meta) (cons sem (cons data meta)))
(define send-subscription-sem  car)
(define send-subscription-data cadr)
(define send-subscription-meta cddr)

(define (make-recv-subscription sem meta) (cons sem meta))
(define recv-subscription-sem  car)
(define recv-subscription-meta cdr)

;; we want to send, so let's notify any receivers that are ready. if
;; this succeeds, we close %sem. otherwise we return #f and we'll need
;; to use our semaphore. %sem must already be locked and open!
(define (gochan-signal-receiver/subscribe chan %sem msg meta)
  ;; because meta is also used to tell if a semaphore has already been
  ;; signalled (#f) or not (≠ #f).
  (if (eq? #f meta) (error "metadata cannot be #f (in gochan-select* alist)"))
  (mutex-lock! (gochan-mutex chan))
  ;; TODO: if closed, signal receiver immediately
  (let ((q (gochan-receivers chan)))
    (let loop ()
      (if (queue-empty? q)
          (begin
            ;; nobody was aroud to receive our data :( we'll need to
            ;; enable receivers to notify us when they need data by
            ;; adding our semaphore to the senders-list:
            (assert (%gosem-open? %sem))
            (queue-add! (gochan-senders chan)
                        (make-send-subscription %sem msg meta)))
          (let ((sub (queue-remove! q)))
            (if (semaphore-signal! (recv-subscription-sem sub) msg
                                   (recv-subscription-meta sub) #t)
                ;; receiver was signalled, signal self
                (begin (gosem-meta-set! %sem meta) ;; close!
                       (void))
                ;; receiver was already signalled by somebody else,
                ;; try next receiver
                (loop))))))
  (mutex-unlock! (gochan-mutex chan)))

;; we want to receive stuff, try to signal someone who's ready to
;; send. %sem must be locked and open!
(define (gochan-signal-sender/subscribe chan %sem meta)
  (if (eq? #f meta) (error "metadata cannot be #f (in gochan-select* alist)"))
  (mutex-lock! (gochan-mutex chan))
  ;; TODO: if closed, signal receiver immediately
  (let ((q (gochan-senders chan)))
    (let loop ()
      (if (queue-empty? q)
          (begin
            ;; nobody had data for us :-( awww. but we can add
            ;; ourselves here so when they do, they can signal us.
            (assert (%gosem-open? %sem))
            (queue-add! (gochan-receivers chan)
                        (make-recv-subscription %sem meta)))
          (let ((sub (queue-remove! q)))
            ;; signalling a sender-semaphore. they don't care about
            ;; data, they just want to be unblocked.
            (if (semaphore-signal! (send-subscription-sem sub) #f (send-subscription-meta sub) #f)
                ;; receiver was signalled. TODO: skip subscribing
                (begin (gosem-meta-set! %sem meta) ;; close
                       (gosem-data-set! %sem (send-subscription-data sub))
                       (gosem-ok-set!   %sem #t))
                ;; sender was already signalled externally, try next
                (loop))))))
  (mutex-unlock! (gochan-mutex chan)))


(define (gochan-select* chans)
  (let ((semaphore (make-semaphore)))
    ;; keep our semaphore locked while we check channels for data
    ;; ready, so that we can't get signalled externally while we do
    ;; this.
    (mutex-lock! (gosem-mutex semaphore))
    (let loop ((chans chans))
      (if (and (%gosem-open? semaphore)
               (pair? chans))
          (let ((chan  (car chans)))
            (match chan
              (((? gochan? chan) meta msg) ;; want to send to chan
               (gochan-signal-receiver/subscribe    chan semaphore msg meta))
              ;; TODO: add support for gotimers here!
              (((? gochan? chan) meta) ;; want to recv on chan
               (gochan-signal-sender/subscribe      chan semaphore meta)))
            (loop (cdr chans)))
          (begin
            (if (%gosem-open? semaphore)
                ;; no data immediately available on any of the
                ;; channels, so we need to wait for somebody else to
                ;; signal us.
                (begin (info "need to wait for data")
                       (mutex-unlock! (gosem-mutex semaphore)
                                      (gosem-cv semaphore) #f))
                ;; yey, semaphore has data already!
                (begin (info "no need to wait, data ready")
                       (mutex-unlock! (gosem-mutex semaphore))))

            ;; TODO: cleanup dangling subscriptions
            ;; (for-each (lambda (achan) (gochan-unsubscribe (car achan) semaphore)) achans)
            (values (gosem-data semaphore)
                    (gosem-ok   semaphore)
                    (gosem-meta semaphore)))))))

(define (gochan-send chan msg)
  (assert (gochan? chan))
  (gochan-select* `((,chan #t ,msg))))

(define (gochan-recv chan)
  (assert (gochan? chan))
  (gochan-select* `((,chan #t))))

(define (gochan-close chan)       (error "TODO"))
(define (gochan-after durationms) (error "TODO"))
(define (gochan-tick durationms)  (error "TODO"))

(define-syntax go
  (syntax-rules ()
    ((_ body ...)
     (thread-start! (lambda () body ...)))))
