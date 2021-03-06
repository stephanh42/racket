#lang racket/base

(require "manual.rkt" "struct.rkt" "scheme.rkt" "decode.rkt"
         racket/string racket/list racket/file
         racket/sandbox racket/promise racket/port file/convertible
         (for-syntax racket/base))

(provide interaction
         interaction0
         interaction-eval
         interaction-eval-show
         racketblock+eval (rename-out [racketblock+eval schemeblock+eval])
         racketblock0+eval
         racketmod+eval (rename-out [racketmod+eval schememod+eval])
         def+int
         defs+int
         examples
         examples*
         defexamples
         defexamples*
         as-examples

         make-base-eval
         make-base-eval-factory
         make-eval-factory
         close-eval

         scribble-eval-handler)

(define scribble-eval-handler
  (make-parameter (lambda (ev c? x) (ev x))))

(define image-counter 0)

(define maxlen 60)

(define-namespace-anchor anchor)

(namespace-require 'racket/base)
(namespace-require '(for-syntax racket/base))

(define (literal-string style s)
  (let ([m (regexp-match #rx"^(.*)(  +)(.*)$" s)])
    (if m
      (make-element #f (list (literal-string style (cadr m))
                             (hspace (string-length (caddr m)))
                             (literal-string style (cadddr m))))
      (make-element style (list s)))))

(define list.flow.list (compose1 list make-flow list))

(define (format-output str style)
  (if (string=? "" str)
    '()
    (list (list.flow.list
           (let ([s (regexp-split #rx"\n" (regexp-replace #rx"\n$" str ""))])
             (if (= 1 (length s))
               (make-paragraph (list (literal-string style (car s))))
               (make-table
                #f
                (map (lambda (s)
                       (list.flow.list
                        (make-paragraph (list (literal-string style s)))))
                     s))))))))

(define (format-output-stream in style)
  (define (add-string string-accum line-accum)
    (if string-accum
      (cons (list->string (reverse string-accum))
            (or line-accum null))
      line-accum))
  (define (add-line line-accum flow-accum)
    (if line-accum
      (cons (make-paragraph
             (map (lambda (s)
                    (if (string? s) (literal-string style s) s))
                  (reverse line-accum)))
            flow-accum)
      flow-accum))
  (let loop ([string-accum #f] [line-accum #f] [flow-accum null])
    (let ([v (read-char-or-special in)])
      (cond
        [(eof-object? v)
         (let* ([line-accum (add-string string-accum line-accum)]
                [flow-accum (add-line line-accum flow-accum)])
           (list
            (list.flow.list
             (if (= 1 (length flow-accum))
               (car flow-accum)
               (make-table
                #f
                (map list.flow.list (reverse flow-accum)))))))]
        [(equal? #\newline v)
         (loop #f #f (add-line (add-string string-accum line-accum)
                               flow-accum))]
        [(char? v)
         (loop (cons v (or string-accum null)) line-accum flow-accum)]
        [else
         (loop #f (cons v (or (add-string string-accum line-accum) null))
               flow-accum)]))))

;; This is probably good to make into some library function at some
;; point (but in that case will need to improve, eg, wrapped lines
;; should start at the same indentation level, etc)
(define (string->wrapped-lines str)
  (define (wrap-line str)
    (if ((string-length str) . <= . maxlen)
      (if (equal? str "") '() (list str))
      (let* ([m (cond [(regexp-match-positions #px"^.*\\S(\\s+).*" str 0 maxlen)
                       => cadr]
                      [else (cons maxlen maxlen)])]
             [r (wrap-line (substring str (cdr m)))])
        (if (= 0 (car m)) r (cons (substring str 0 (car m)) r)))))
  (append-map wrap-line (regexp-split #px"\\s*\n" str)))

(define (interleave inset? title expr-paras val-list+outputs)
  (let ([lines
         (let loop ([expr-paras expr-paras]
                    [val-list+outputs val-list+outputs]
                    [first? #t])
           (if (null? expr-paras)
             null
             (append
              (list (list (let ([p (car expr-paras)])
                            (if (flow? p) p (make-flow (list p))))))
              (format-output (cadar val-list+outputs) output-color)
              (format-output (caddar val-list+outputs) error-color)
              (cond
                [(string? (caar val-list+outputs))
                 ;; Error result case:
                 (map (lambda (s) (car (format-output s error-color)))
                      (string->wrapped-lines (caar val-list+outputs)))]
                [(box? (caar val-list+outputs))
                 ;; Output written to a port
                 (format-output-stream (unbox (caar val-list+outputs))
                                       result-color)]
                [else
                 ;; Normal result case:
                 (let ([val-list (caar val-list+outputs)])
                   (if (equal? val-list (list (void)))
                     null
                     (map (lambda (v)
                            (list.flow.list
                             (make-paragraph
                              (list (elem #:style result-color
                                          (to-element/no-color
                                           v #:expr? (print-as-expression)))))))
                          val-list)))])
              (loop (cdr expr-paras) (cdr val-list+outputs) #f))))])
    (if inset?
      (let ([p (code-inset (make-table #f lines))])
        (if title
          (make-table #f (list (list.flow.list title) (list.flow.list p)))
          p))
      (make-table #f (if title (cons (list.flow.list title) lines) lines)))))

;; extracts from a datum or syntax object --- while keeping the
;; syntax-objectness of the original intact, instead of always
;; generating a syntax object or always generating a datum
(define (extract s . ops)
  (let loop ([s s] [ops ops])
    (cond [(null? ops) s]
          [(syntax? s) (loop (syntax-e s) ops)]
          [else (loop ((car ops) s) (cdr ops))])))

(struct nothing-to-eval ())

(define (extract-to-evaluate s)
  (let loop ([s s] [expect #f])
    (syntax-case s (code:line code:comment eval:alts eval:check)
      [(code:line v (code:comment . rest))
       (loop (extract s cdr car) expect)]
      [(code:comment . rest)
       (values (nothing-to-eval) expect)]
      [(eval:alts p e)
       (loop (extract s cdr cdr car) expect)]
      [(eval:check e expect)
       (loop (extract s cdr car)
             (list (syntax->datum (datum->syntax #f (extract s cdr cdr car)))))]
      [else (values s expect)])))

(define (do-eval ev who)
  (define (get-outputs)
    (define (get getter what)
      (define s (getter ev))
      (if (string? s)
        s
        (error who "missing ~a, possibly from a sandbox ~a"
               what "without a `sandbox-output' configured to 'string")))
    (list (get get-output "output") (get get-error-output "error output")))
  (define (render-value v)
    (if (call-in-sandbox-context
         ev (let ([cp (current-print)])
              (lambda () (and (eq? (current-print) cp) (print-as-expression)))))
      ;; default printer => get result as S-expression
      (make-reader-graph (copy-value v (make-hasheq)))
      ;; other printer => go through a string
      (box (call-in-sandbox-context
            ev
            (lambda ()
              (define-values [in out] (make-pipe-with-specials))
              (parameterize ([current-output-port out]) (map (current-print) v))
              (close-output-port out)
              in)))))
  (define (do-ev s)
    (with-handlers ([(lambda (x) (not (exn:break? x)))
                     (lambda (e)
                       (cons (if (exn? e)
                               (exn-message e)
                               (format "uncaught exception: ~s" e))
                             (get-outputs)))])
      (cons (render-value (do-plain-eval ev s #t)) (get-outputs))))
  (define (do-ev/expect s expect)
    (define r (do-ev s))
    (when expect
      (let ([expect (do-plain-eval ev (car expect) #t)])
        (unless (equal? (car r) expect)
          (raise-syntax-error 'eval "example result check failed" s))))
    r)
  (lambda (str)
    (let-values ([(s expect) (extract-to-evaluate str)])
      (if (nothing-to-eval? s)
        (values (list (list (void)) "" ""))
        (do-ev/expect s expect)))))

;; Since we evaluate everything in an interaction before we typeset,
;;  copy each value to avoid side-effects.
(define (copy-value v ht)
  (define (install v v2) (hash-set! ht v v2) v2)
  (let loop ([v v])
    (cond
      [(and v (hash-ref ht v #f)) => (lambda (v) v)]
      [(syntax? v) (make-literal-syntax v)]
      [(string? v) (install v (string-copy v))]
      [(bytes? v) (install v (bytes-copy v))]
      [(pair? v)
       (let ([ph (make-placeholder #f)])
         (hash-set! ht v ph)
         (placeholder-set! ph (cons (loop (car v)) (loop (cdr v))))
         ph)]
      [(mpair? v)
       (let ([p (mcons #f #f)])
         (hash-set! ht v p)
         (set-mcar! p (loop (mcar v)))
         (set-mcdr! p (loop (mcdr v)))
         p)]
      [(vector? v)
       (let ([v2 (make-vector (vector-length v))])
         (hash-set! ht v v2)
         (for ([i (in-range (vector-length v2))])
           (vector-set! v2 i (loop (vector-ref v i))))
         v2)]
      [(box? v)
       (let ([v2 (box #f)])
         (hash-set! ht v v2)
         (set-box! v2 (loop (unbox v)))
         v2)]
      [(hash? v)
       (let ([ph (make-placeholder #f)])
         (hash-set! ht v ph)
         (let ([a (hash-map v (lambda (k v) (cons (loop k) (loop v))))])
           (placeholder-set!
            ph
            (cond [(hash-eq? v) (make-hasheq-placeholder a)]
                  [(hash-eqv? v) (make-hasheqv-placeholder a)]
                  [else (make-hash-placeholder a)])))
         ph)]
      [else v])))

(define (strip-comments stx)
  (cond
    [(syntax? stx)
     (datum->syntax stx (strip-comments (syntax-e stx)) stx stx stx)]
    [(pair? stx)
     (define a (car stx))
     (define (comment? a)
       (and (pair? a)
            (or (eq? (car a) 'code:comment)
                (and (identifier? (car a))
                     (eq? (syntax-e (car a)) 'code:comment)))))
     (if (or (comment? a) (and (syntax? a) (comment? (syntax-e a))))
       (strip-comments (cdr stx))
       (cons (strip-comments a)
             (strip-comments (cdr stx))))]
    [(eq? stx 'code:blank) (void)]
    [else stx]))

(define (make-base-eval)
  (call-with-trusted-sandbox-configuration
   (lambda ()
     (parameterize ([sandbox-output 'string]
                    [sandbox-error-output 'string]
                    [sandbox-propagate-breaks #f])
       (let ([e (make-evaluator '(begin))])
         (let ([ns (namespace-anchor->namespace anchor)])
           (call-in-sandbox-context
            e
            (lambda () (namespace-attach-module ns 'file/convertible))))
         e)))))

(define (make-base-eval-factory mod-paths)
  (let ([ns (delay (let ([ns (make-base-empty-namespace)])
                     (parameterize ([current-namespace ns])
                       (for ([mod-path (in-list mod-paths)])
                         (dynamic-require mod-path #f)))
                     ns))])
    (lambda ()
      (let ([ev (make-base-eval)]
            [ns (force ns)])
        ((scribble-eval-handler)
         ev #f
         `(,(lambda ()
              (for ([mod-path (in-list mod-paths)])
                (namespace-attach-module ns mod-path)))))
        ev))))

(define (make-eval-factory mod-paths)
  (let ([base-factory (make-base-eval-factory mod-paths)])
    (lambda ()
      (let ([ev (base-factory)])
        ((scribble-eval-handler)
         ev #f
         `(,(lambda ()
              (for ([mod-path (in-list mod-paths)])
                (namespace-require mod-path)))))
        ev))))

(define (close-eval e)
  (kill-evaluator e)
  "")

(define (do-plain-eval ev s catching-exns?)
  (parameterize ([sandbox-propagate-breaks #f])
    (call-with-values
        (lambda ()
          ((scribble-eval-handler)
           ev
           catching-exns?
           (let ([s (strip-comments s)])
             (cond [(syntax? s)
                    (syntax-case s (module)
                      [(module . _rest) (syntax->datum s)]
                      [_else s])]
                   [(bytes? s) `(begin ,s)]
                   [(string? s) `(begin ,s)]
                   [else s]))))
        list)))

;; Quote an expression to be evaluated:
(define-syntax-rule (quote-expr e) 'e)
;; This means that sandbox evaluation always works on sexprs, to get
;; it to work on syntaxes, use this definition:
;;   (require syntax/strip-context)
;;   (define-syntax-rule (quote-expr e) (strip-context (quote-syntax e)))

(define (do-interaction-eval ev e)
  (let-values ([(e expect) (extract-to-evaluate e)])
    (unless (nothing-to-eval? e)
      (parameterize ([current-command-line-arguments #()])
        (do-plain-eval (or ev (make-base-eval)) e #f)))
    ""))

(define-syntax interaction-eval
  (syntax-rules ()
    [(_ #:eval ev e) (do-interaction-eval ev (quote-expr e))]
    [(_ e) (do-interaction-eval #f (quote-expr e))]))

(define (show-val v)
  (elem #:style result-color
        (to-element/no-color v #:expr? (print-as-expression))))

(define (do-interaction-eval-show ev e)
  (parameterize ([current-command-line-arguments #()])
    (show-val (car (do-plain-eval (or ev (make-base-eval)) e #f)))))

(define-syntax interaction-eval-show
  (syntax-rules ()
    [(_ #:eval ev e) (do-interaction-eval-show ev (quote-expr e))]
    [(_ e) (do-interaction-eval-show #f (quote-expr e))]))

(define-syntax racketinput*
  (syntax-rules (eval:alts code:comment)
    [(_ (code:comment . rest)) (racketblock0 (code:comment . rest))]
    [(_ (eval:alts a b)) (racketinput* a)]
    [(_ e) (racketinput0 e)]))

(define-code racketblock0+line (to-paragraph/prefix "" "" (list " ")))

(define-syntax (racketdefinput* stx)
  (syntax-case stx (define define-values define-struct)
    [(_ (define . rest))
     (syntax-case stx ()
       [(_ e) #'(racketblock0+line e)])]
    [(_ (define-values . rest))
     (syntax-case stx ()
       [(_ e) #'(racketblock0+line e)])]
    [(_ (define-struct . rest))
     (syntax-case stx ()
       [(_ e) #'(racketblock0+line e)])]
    [(_ (code:line (define . rest) . rest2))
     (syntax-case stx ()
       [(_ e) #'(racketblock0+line e)])]
    [(_ e) #'(racketinput* e)]))

(define (do-titled-interaction who inset? ev t shows evals)
  (interleave inset? t shows (map (do-eval ev who) evals)))

(define-syntax titled-interaction
  (syntax-rules ()
    [(_ who inset? #:eval ev t racketinput* e ...)
     (do-titled-interaction
      'who inset? ev t (list (racketinput* e) ...) (list (quote-expr e) ...))]
    [(_ who inset? t racketinput* e ...)
     (titled-interaction
      who inset? #:eval (make-base-eval) t racketinput* e ...)]))

(define-syntax (-interaction stx)
  (syntax-case stx ()
    [(_ who #:eval ev e ...)
     (syntax/loc stx
       (titled-interaction who #f #:eval ev #f racketinput* e ...))]
    [(_ who e ...)
     (syntax/loc stx
       (titled-interaction who #f #f racketinput* e ...))]))

(define (code-inset p)
  (make-blockquote 'code-inset (list p)))

(define-syntax (interaction stx)
  (syntax-case stx ()
    [(H e ...) (syntax/loc stx (code-inset (-interaction H e ...)))]))

(define-syntax (interaction0 stx)
  (syntax-case stx ()
    [(H e ...) (syntax/loc stx (-interaction H e ...))]))

(define-syntax racketblock+eval
  (syntax-rules ()
    [(_ #:eval ev e ...)
     (let ([eva ev])
       (#%expression
        (begin (interaction-eval #:eval eva e) ...
               (racketblock e ...))))]
    [(_ e ...)
     (racketblock+eval #:eval (make-base-eval) e ...)]))

(define-syntax racketblock0+eval
  (syntax-rules ()
    [(_ #:eval ev e ...)
     (let ([eva ev])
       (#%expression (begin (interaction-eval #:eval eva e) ...
                            (racketblock0 e ...))))]
    [(_ e ...)
     (racketblock0+eval #:eval (make-base-eval) e ...)]))

(define-syntax racketmod+eval
  (syntax-rules ()
    [(_ #:eval ev name e ...)
     (let ([eva ev])
       (#%expression
        (begin (interaction-eval #:eval eva e) ...
               (racketmod name e ...))))]
    [(_ name e ...)
     (racketmod+eval #:eval (make-base-eval) name e ...)]))

(define-syntax (def+int stx)
  (syntax-case stx ()
    [(H #:eval ev def e ...)
     (syntax/loc stx
       (let ([eva ev])
         (column (list (racketblock0+eval #:eval eva def)
                       blank-line
                       (-interaction H #:eval eva e ...)))))]
    [(_ def e ...)
     (syntax/loc stx (def+int #:eval (make-base-eval) def e ...))]))

(define-syntax (defs+int stx)
  (syntax-case stx ()
    [(H #:eval ev [def ...] e ...)
     (syntax/loc stx
       (let ([eva ev])
         (column (list (racketblock0+eval #:eval eva def ...)
                       blank-line
                       (-interaction H #:eval eva e ...)))))]
    [(_ [def ...] e ...)
     (syntax/loc stx (defs+int #:eval (make-base-eval) [def ...] e ...))]))

(define example-title
  (make-paragraph (list "Example:")))
(define examples-title
  (make-paragraph (list "Examples:")))

(define-syntax pick-example-title
  (syntax-rules ()
    [(_ e) example-title]
    [(_ . _) examples-title]))

(define-syntax (examples stx)
  (syntax-case stx ()
    [(H #:eval ev e ...)
     (syntax/loc stx
       (titled-interaction
        H #t #:eval ev (pick-example-title e ...) racketinput* e ...))]
    [(H e ...)
     (syntax/loc stx
       (titled-interaction
        H #t (pick-example-title e ...)  racketinput* e ...))]))
(define-syntax (examples* stx)
  (syntax-case stx ()
    [(H #:eval ev example-title e ...)
     (syntax/loc stx
       (titled-interaction H #t #:eval ev example-title racketinput* e ...))]
    [(H example-title e ...)
     (syntax/loc stx
       (titled-interaction H #t example-title racketinput* e ...))]))
(define-syntax (defexamples stx)
  (syntax-case stx ()
    [(H #:eval ev e ...)
     (syntax/loc stx
       (titled-interaction
        H #t #:eval ev (pick-example-title e ...)  racketdefinput* e ...))]
    [(H e ...)
     (syntax/loc stx
       (titled-interaction
        H #t (pick-example-title e ...)  racketdefinput* e ...))]))
(define-syntax (defexamples* stx)
  (syntax-case stx ()
    [(H #:eval ev example-title e ...)
     (syntax/loc stx
       (titled-interaction H #t #:eval ev example-title racketdefinput* e ...))]
    [(H example-title e ...)
     (syntax/loc stx
       (titled-interaction H #t example-title racketdefinput* e ...))]))

(define blank-line (make-paragraph (list 'nbsp)))

(define (column l)
  (code-inset (make-table #f (map list.flow.list l))))

(define (do-splice l)
  (cond [(null? l) null]
        [(splice? (car l)) `(,@(splice-run (car l)) ,@(do-splice (cdr l)))]
        [else (cons (car l) (do-splice (cdr l)))]))

(define as-examples
  (case-lambda
    [(t) (as-examples examples-title t)]
    [(example-title t)
     (make-table #f (list (list.flow.list example-title)
                          (list (make-flow (do-splice (list t))))))]))
