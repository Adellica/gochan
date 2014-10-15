;; gochan.scm -- thread-safe channel (FIFO) library
;; Copyright (c) 2012 Alex Shinn.  All rights reserved.
;; Copyright (c) 2014 Kristian Lein-Mathisen.  All rights reserved.
;; BSD-style license: http://synthcode.com/license.txt
;;
;; Inspired by channels from goroutines.

(use srfi-18)

(define-record-type gochan
  (%make-gochan mutex condvar front rear closed?)
  gochan?
  (mutex gochan-mutex gochan-mutex-set!)
  (condvar gochan-condvar gochan-condvar-set!)
  (front gochan-front gochan-front-set!)
  (rear gochan-rear gochan-rear-set!)
  (closed? gochan-closed? gochan-closed-set!))

(define (make-gochan)
  (%make-gochan (make-mutex) (make-condition-variable) '() '() #f))

(define (gochan-empty? chan)
  (null? (gochan-front chan)))

(define (gochan-send chan obj)
  (mutex-lock! (gochan-mutex chan))
  (when (gochan-closed? chan)
    (begin (mutex-unlock! (gochan-mutex chan))
           (error "cannot send to closed gochan" chan)))
  (let ((new (list obj))
        (rear (gochan-rear chan)))
    (gochan-rear-set! chan new)
    (cond
     ((pair? rear)
      (set-cdr! rear new))
     (else ;; sending to empty gochan
      (gochan-front-set! chan new)
      (condition-variable-broadcast! (gochan-condvar chan)))))
  (mutex-unlock! (gochan-mutex chan)))

;; wrap msg in a list. return #f if channel is closed.
(define (gochan-receive* chan)
  (mutex-lock! (gochan-mutex chan))
  (let ((front (gochan-front chan)))
    (cond
     ((null? front) ;; receiving from empty gochan
      (cond ((gochan-closed? chan)
             (mutex-unlock! (gochan-mutex chan))
             #f) ;; #f for fail
            (else
             (mutex-unlock! (gochan-mutex chan) (gochan-condvar chan))
             (gochan-receive* chan))))
     (else
      (gochan-front-set! chan (cdr front))
      (if (null? (cdr front))
          (gochan-rear-set! chan '()))
      (mutex-unlock! (gochan-mutex chan))
      (list (car front)))))) ;; (list <msg>)

(define (gochan-receive chan)
  (cond ((gochan-receive* chan) => car)
        (else (error "channel is closed" chan))))

(define (gochan-close c)
  (mutex-lock! (gochan-mutex c))
  (gochan-closed-set! c #t)
  (condition-variable-broadcast! (gochan-condvar c)) ;; signal
  (mutex-unlock! (gochan-mutex c)))

;; apply proc to each incoming msg as they appear on the channel,
;; return (void) when channel is emptied and closed.
(define (gochan-for-each c proc)
  (let loop ()
    (cond ((gochan-receive* c) =>
           (lambda (msg)
             (proc (car msg))
             (loop))))))
