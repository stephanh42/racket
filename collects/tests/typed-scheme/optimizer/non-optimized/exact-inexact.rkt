(module exact-inexact typed/scheme 
  (require racket/flonum)
  (exact->inexact (expt 10 100))) ; must not be a fixnum