#lang typed/scheme
#:optimize
(require racket/unsafe/ops)
(car (cdr '(1 2)))