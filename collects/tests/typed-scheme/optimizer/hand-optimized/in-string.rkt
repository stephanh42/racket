#lang racket
(require racket/unsafe/ops)
;; the following code should be equivalent to the code generated by:
;; (for: ((i : Char (in-string "123")))
;;   (display i))
(let-values (((pos->vals pos-next init pos-cont? val-cont? all-cont?)
              (let* ((i "123")
                     (len (string-length i)))
                (values (lambda (x) (string-ref i x))
                        (lambda (x) (unsafe-fx+ 1 x))
                        0
                        (lambda (x) (unsafe-fx< x len))
                        (lambda (x) #t)
                        (lambda (x y) #t)))))
  (void)
  ((letrec-values (((for-loop)
                    (lambda
                     (fold-var pos)
                     (if (pos-cont? pos)
                         (let-values (((i) (pos->vals pos)))
                           (if (val-cont? i)
                               (let-values (((fold-var)
                                             (let-values (((fold-var)
                                                           fold-var))
                                               (let-values ()
                                                 (let-values ()
                                                   (display i))
                                                 (void)))))
                                 (if (all-cont? pos i)
                                     (for-loop fold-var (pos-next pos))
                                     fold-var))
                               fold-var))
                         fold-var))))
                  for-loop)
   (void)
   init))
(void)