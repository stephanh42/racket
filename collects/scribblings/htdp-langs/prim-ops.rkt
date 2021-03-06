#reader scribble/reader
#lang racket/base
(require "common.rkt"
         scribble/decode
         scribble/struct
         scribble/racket
         racket/list
         racket/pretty
         syntax/docprovide
         (for-syntax racket/base)
         )

(provide prim-variables
         prim-forms
         define-forms/normal
         define-form/explicit-lambda
         beginner-abbr-forms
         intermediate-forms
         prim-ops
         prim-op-defns)

(define (maybe-make-table l t)
  (if (paragraph? t)
      (make-paragraph
       (append l (cons " "
                       (paragraph-content t))))
      (make-table
       "prototype"
       (list (list (make-flow (list (make-paragraph l)))
                   (make-flow (list t)))))))


(define (typeset-type type)
  (let-values ([(in out) (make-pipe)])
    (parameterize ([pretty-print-columns 50])
      (pretty-write type out))
    (port-count-lines! in)
    (read-syntax #f in)))

(define (sort-category category)
  (sort
   (cadr category)
   (lambda (x y)
     (string<=? (symbol->string (car x))
                (symbol->string (car y))))))


(define (make-proto func ctx-stx)
  (maybe-make-table
   (list
    (hspace 2)
    (to-element (datum->syntax ctx-stx (car func)))
    (hspace 1)
    ":"
    (hspace 1))
   (to-paragraph
    (typeset-type (cadr func)))))

(define-syntax-rule (prim-variables (section-prefix) empty true false)
  (make-splice
   (list
    @section[#:tag (string-append section-prefix " Pre-Defined Variables")]{Pre-Defined Variables}

    @defthing[empty empty?]{

    The empty list.}

    @defthing[true boolean?]{

    The true value.}

    @defthing[false boolean?]{

    The false value.})))

;; ----------------------------------------

(define-syntax-rule (define-forms/normal define)
  (gen-define-forms/normal #'define @racket[define]))

(define (gen-define-forms/normal define-id define-elem)
  ;; Since `define' has a source location different from the use site,
  ;; use the `#:id [spec-id bind-id]' form in `defform*':
  (list
   @defform*[#:id [define define-id]
             [(define (name variable variable ...) expression)]]{

   Defines a function named @racket[name]. The @racket[expression] is the body
   of the function. When the function is called,
   the values of the arguments are inserted into the body in place of the
   @racket[variable]s. The function returns the value of that new expression.

   The function name's cannot be the same as that of another function or
   variable.}

   @defform/none[(@#,define-elem name expression)]{

   Defines a variable called @racket[name] with the the value of
   @racket[expression]. The variable name's cannot be the same as that of
   another function or variable, and @racket[name] itself must not appear in
   @racket[expression].}))

;; ----------------------------------------

(define-syntax-rule (define-form/explicit-lambda define lambda)
  (gen-define-form/explicit-lambda @racket[define] 
                                   #'lambda @racket[lambda]))

(define (gen-define-form/explicit-lambda define-elem lambda-id lambda-elem)
  (list
   @defform/none[(#,define-elem name (#,lambda-elem (variable variable ...) expression))]{

   An alternate way on defining functions. The @racket[name] is the name of
   the function, which cannot be the same as that of another function or
   variable. 

   A @defidform/inline[#,lambda-id] cannot be used outside of this alternate syntax.}))

;; ----------------------------------------

(define-syntax-rule (prim-forms 
                     (section-prefix)
                     define 
                     lambda
                     define-struct [ds-extra ...]
                     define-wish
                     cond
                     else
                     if
                     and 
                     or
                     check-expect
                     check-within
                     check-error
                     check-member-of
                     check-range
                     require
                     true
                     false
                     #:with-beginner-function-call with-beginner-function-call)
  (gen-prim-forms #'define-struct @racket[define-struct] (list ds-extra ...)
                  #'cond @racket[cond]
                  #'else @racket[else]
                  #'if @racket[if]
                  #'or @racket[or]
                  #'and @racket[and]
                  #'check-expect @racket[check-expect]
                  #'check-within @racket[check-within]
                  #'check-error @racket[check-error]
                  #'check-member-of @racket[check-member-of]
                  #'check-range @racket[check-range]
                  #'require @racket[require]
                  @racket[true] @racket[false]
                  with-beginner-function-call))

(define (gen-prim-forms define-struct-id define-struct-elem ds-extras
                        cond-id cond-elem
                        else-id else-elem
                        if-id if-elem
                        and-id and-elem
                        or-id or-elem
                        check-expect-id check-expect-elem
                        check-within-id check-within-elem
                        check-error-id check-error-elem
                        check-member-of-id check-member-of-elem
                        check-range-id check-range-elem
                        require-id require-elem
                        true-elem false-elem
                        with-beginner-function-call)
  (list
   @; ----------------------------------------------------------------------

  @defform*[#:id [define-struct define-struct-id]
            [(define-struct structure-name (field-name ...))]]{

   Defines a new structure called @racket[structure-name]. The structure's fields are
   named by the @racket[field-name]s. After the @define-struct-elem, the following new
   functions are available:

   @itemize[

     @item{@racketidfont{make-}@racket[structure-name] : takes a number of
           arguments equal to the number of fields in the structure,
           and creates a new instance of that structure.}

     @item{@racket[structure-name]@racketidfont{-}@racket[field-name] : takes an
           instance of the structure and returns the value in the field named by
           @racket[field-name].}

     @item{@racket[structure-name]@racketidfont{?} : takes any value, and returns
           @true-elem if the value is an instance of the structure.}
   ]

   The name of the new functions introduced by @define-struct-elem
   must not be the same as that of other functions or variables,
   otherwise @define-struct-elem reports an error.

   @ds-extras}

  #|

  @defform*[[(define-wish name)]]{                           
                           
  Defines a function called @racket[name] that we wish exists but have not
  implemented yet. The wished-for function can be called with one argument, and
  are reported in the test report for the current program.

  The name of the function cannot be the same as another function or variable.}


  @defform/none[#:literals (define-wish)
                (define-wish name expression)]{
  Similar to the above form, defines a wished-for function named @racket[name]. If the 
  wished-for function is called with one value, it returns the values of @racket[expression]. }
  |#

  @; ----------------------------------------------------------------------

  @(if with-beginner-function-call
       @defform/none[(name expression expression ...)]{
        Calls the function named @racket[name]. The value of the call is the
        value of @racket[name]'s body when every one of the function's
        variables are replaced by the values of the corresponding
        @racket[expression]s.
     
        The function named @racket[name] must defined before it can be called. The
        number of argument @racket[expression]s must be the same as the number of arguments
        expected by the function.}
       @elem[])

  @; ----------------------------------------------------------------------

  @defform*[#:id [cond cond-id]
            #:literals (else)
            [(cond [question-expression answer-expression] ...)
             (#,cond-elem [question-expression answer-expression]
                          ... 
                          [#,else-elem answer-expression])]]{

    Chooses a clause based on some condition. @racket[cond] finds the first
    @racket[question-expression] that evaluates to @true-elem, then
    evaluates the corresponding @racket[answer-expression].

    If none of the @racket[question-expression]s evaluates to @true-elem,
    @cond-elem's value is the @racket[answer-expression] of the
    @else-elem clause. If there is no @else-elem, @cond-elem reports
    an error. If the result of a @racket[question-expression] is neither
    @true-elem nor @false-elem, @cond-elem also reports an error.
    
    @defidform/inline[#,else-id] cannot be used outside of @|cond-elem|.}

  @; ----------------------------------------------------------------------

  @defform*[#:id [if if-id]
            [(if test-expression then-expression else-expression)]]{

   When the value of the @racket[test-expression] is @true-elem,
   @if-elem evaluates the @racket[then-expression]. When the test is
   @false-elem, @if-elem evaluates the @racket[else-expression].

   If the @racket[test-expression] is neither @true-elem nor
   @false-elem, @if-elem reports an error.}

  @; ----------------------------------------------------------------------

  @defform*[#:id [and and-id]
            [(and expression expression expression ...)]]{

    Evaluates to @true-elem if all the @racket[expression]s are
    @|true-elem|. If any @racket[expression] is @|false-elem|, the @and-elem
    expression immediately evaluates to @false-elem (and the expressions to the
    right of that expression are not evaluated.)

    If any of the expressions evaluate to a value other than @true-elem or
    @false-elem, @and-elem reports an error.}

  @; ----------------------------------------------------------------------


  @defform*[#:id [or or-id]
            [(or expression expression expression ...)]]{

    Evaluates to @true-elem as soon as one of the
    @racket[expression]s is @true-elem (and the expressions to the right of that
    expression are not evaluated.) If all of the @racket[expression]s are @|false-elem|,
    the @or-elem expression evaluates to @|false-elem|.

    If any of the expressions evaluate to a value other than @true-elem or
    @false-elem, @or-elem reports an error.}

  @; ----------------------------------------------------------------------


  @defform*[#:id [check-expect check-expect-id]
            [(check-expect expression expected-expression)]]{

   Checks that the first @racket[expression] evaluates to the same value as the
   @racket[expected-expression].}


  @defform*[#:id [check-within check-within-id]
            [(check-within expression expected-expression delta-expression)]]{

   Checks that the first @racket[expression] evaluates to a value within
   @racket[delta-expression] of the @racket[expected-expression]. If
   @racket[delta-expression] is not a number, @check-within-elem reports an
   error.}


  @defform*[#:id [check-error check-error-id]
            [(check-error expression match-expression)
             (#,check-error-elem expression)]]{

   Checks that the @racket[expression] reports an error,
   where the error messages matches the
   value of @racket[matchexpression], if it is present.}


  @defform*[#:id [check-member-of check-member-of-id]
            [(check-member-of expression expression expression ...)]]{

   Checks that the value of the first @racket[expression] as that of
   one of the following @racket[expression]s.}


  @defform*[#:id [check-range check-range-id]
            [(check-range expression low-expression high-expression)]]{

   Checks that the value of the first @racket[expression] is a number in
   between the value of the @racket[low-expression] and the
   @racket[high-expression], inclusive.}

  @; ----------------------------------------------------------------------

  @defform*[#:id [require require-id]
            [(require string)]]{

   Makes the definitions of the module specified by @racket[string]
   available in the current module (i.e., the current file), where
   @racket[string] refers to a file relative to the current file.

   The @racket[string] is constrained in several ways to avoid
   problems with different path conventions on different platforms: a
   @litchar{/} is a directory separator, @litchar{.} always means the
   current directory, @litchar{..} always means the parent directory,
   path elements can use only @litchar{a} through @litchar{z}
   (uppercase or lowercase), @litchar{0} through @litchar{9},
   @litchar{-}, @litchar{_}, and @litchar{.}, and the string cannot be
   empty or contain a leading or trailing @litchar{/}.}


  @defform/none[(#,require-elem module-name)]{

   Accesses a file in an installed library. The library name is an
   identifier with the same constraints as for a relative-path string
   (though without the quotes), with the additional constraint that it
   must not contain a @litchar{.}.}

  @defform/none[(#,require-elem (lib string string ...))]{

  Accesses a file in an installed library, making its definitions
  available in the current module (i.e., the current file). The first
  @racket[string] names the library file, and the remaining
  @racket[string]s name the collection (and sub-collection, and so on)
  where the file is installed. Each string is constrained in the same
  way as for the @racket[(#,require-elem string)] form.}


  @defform/none[#:literals (planet)
                (#,require-elem (planet string (string string number number)))]{

  Accesses a library that is distributed on the internet via the
  @|PLaneT| server, making it definitions available in the current module
  (i.e., current file).}))

;; ----------------------------------------

(define-syntax-rule
  (beginner-abbr-forms quote quasiquote unquote unquote-splicing)
  (gen-beginner-abbr-forms #'quote @racket[quote]
                           #'quasiquote @racket[quasiquote]
                           #'unquote @racket[unquote]
                           #'unquote-splicing @racket[unquote-splicing]))

(define (gen-beginner-abbr-forms quote-id quote-elem
                                 quasiquote-id quasiquote-elem
                                 unquote-id unquote-elem
                                 unquote-splicing-id unquote-splicing-elem)
  
  (list
   @deftogether[(
    @defform/none[(unsyntax @elem{@racketvalfont{'}@racket[name]})]
    @defform/none[(unsyntax @elem{@racketvalfont{'}@racket[part]})]
    @defform[#:id [quote quote-id] (quote name)]
    @defform/none[(#,quote-elem part)]
   )]{
 
    A quoted name is a symbol. A quoted part is an abbreviation for a nested lists.
 
    Normally, this quotation is written with a @litchar{'}, like
    @racket['(apple banana)], but it can also be written with
    @quote-elem, like @racket[(@#,quote-elem (apple banana))].}
 
 
   @deftogether[(
    @defform/none[(unsyntax @elem{@racketvalfont{`}@racket[name]})]
    @defform/none[(unsyntax @elem{@racketvalfont{`}@racket[part]})]
    @defform[#:id [quasiquote quasiquote-id]
             (quasiquote name)]
    @defform/none[(#,quasiquote-elem part)]
   )]{
 
    Like @quote-elem, but also allows escaping to expression
    ``unquotes.''
 
    Normally, quasi-quotations are written with a backquote,
    @litchar{`}, like @racket[`(apple ,(+ 1 2))], but they can also be
    written with @quasiquote-elem, like
    @racket[(@quasiquote-elem (apple ,(+ 1 2)))].}
 
 
   @deftogether[(
    @defform/none[(unsyntax @elem{@racketvalfont{,}@racket[expression]})]
    @defform[#:id [unquote unquote-id]
             (unquote expression)]
   )]{
 
    Under a single quasiquote, @racketfont{,}@racket[expression]
    escapes from the quote to include an evaluated expression whose
    result is inserted into the abbreviated list.
 
    Under multiple quasiquotes, @racketfont{,}@racket[expression] is
    really the literal @racketfont{,}@racket[expression], decrementing
    the quasiquote count by one for @racket[expression].
 
    Normally, an unquote is written with @litchar{,}, but it can also be
    written with @|unquote-elem|.}
 
 
   @deftogether[(
    @defform/none[(unsyntax @elem{@racketvalfont[",@"]@racket[expression]})]
    @defform[#:id [unquote-splicing unquote-splicing-id]
             (unquote-splicing expression)]
   )]{
 
    Under a single quasiquote, @racketfont[",@"]@racket[expression]
    escapes from the quote to include an evaluated expression whose
    result is a list to splice into the abbreviated list.
 
    Under multiple quasiquotes, a splicing unquote is like an unquote;
    that is, it decrements the quasiquote count by one.
 
    Normally, a splicing unquote is written with @litchar{,}, but it
    can also be written with @|unquote-splicing-elem|.}

    ))


(define-syntax-rule 
  (intermediate-forms lambda
                      local
                      letrec
                      let*
                      let
                      time
                      define
                      define-struct)
  (gen-intermediate-forms #'lambda @racket[lambda]
                          #'local @racket[local]
                          #'letrec @racket[letrec]
                          #'let* @racket[let*]
                          #'let @racket[let]
                          #'time @racket[time]
                          @racket[define] 
                          @racket[define-struct]))

(define (gen-intermediate-forms lambda-id lambda-elem
                                local-id local-elem
                                letrec-id letrec-elem
                                let*-id let*-elem
                                let-id let-elem
                                time-id time-elem
                                define-elem
                                define-struct-elem
                                )
  (list

  @defform[#:id [local local-id]
           (local [definition ...] expression)]{

   Groups related definitions for use in @racket[expression]. Each
   @racket[definition] can be either a @define-elem or a
   @|define-struct-elem|. 

   When evaluating @local-elem, each @racket[definition] is evaluated
   in order, and finally the body @racket[expression] is
   evaluated. Only the expressions within the @local-elem (including
   the right-hand-sides of the @racket[definition]s and the
   @racket[expression]) may refer to the names defined by the
   @racket[definition]s. If a name defined in the @local-elem is the
   same as a top-level binding, the inner one ``shadows'' the outer
   one. That is, inside the @local-elem, any references to that name
   refer to the inner one.}

  @; ----------------------------------------------------------------------

  @defform[#:id [letrec letrec-id]
           (letrec ([name expr-for-let] ...) expression)]{

   Like @local-elem, but with a simpler syntax. Each @racket[name]
   defines a variable (or a function) with the value of the
   corresponding @racket[expr-for-let].  If @racket[expr-for-let] is a
   @lambda-elem, @letrec-elem defines a function, otherwise it
   defines a variable.}


  @defform[#:id [let* let*-id]
           (let* ([name expr-for-let] ...) expression)]{

   Like @letrec-elem, but each @racket[name] can only be used in
   @racket[expression], and in @racket[expr-for-let]s occuring after
   that @racket[name].}


  @defform[#:id [let let-id]
           (let ([name expr-for-let] ...) expression)]{

   Like @letrec-elem, but the defined @racket[name]s can be used only
   in the last @racket[expression], not the @racket[expr-for-let]s
   next to the @racket[name]s.}

  @; ----------------------------------------------------------------------

  @defform[#:id [time time-id]
            (time expression)]{

   Measures the time taken to evaluate @racket[expression]. After
   evaluating @racket[expression], @racket[time] prints out the time
   taken by the evaluation (including real time, time taken by the
   CPU, and the time spent collecting free memory). The value of
   @time-elem is the same as that of @racket[expression].}))

;; ----------------------------------------

(define (prim-ops lib ctx-stx)
  (let ([ops (map (lambda (cat)
                    (cons (car cat)
                          (list (cdr cat))))
                  (lookup-documentation lib 'procedures))])
    (make-table
     #f
     (cons
      (list
       (make-flow
        (list
         (make-paragraph
          (list "In function calls, the function appearing immediatly after the open parenthesis can be any functions
defined with " (racket define) " or " (racket define-struct) ", or any one of:")))))
      (apply
       append
       (map (lambda (category)
              (cons
               (list (make-flow
                      (list
                       (make-paragraph (list (hspace 1)
                                             (bold (car category)))))))
               (map (lambda (func)
                      (list
                       (make-flow
                        (list
                         (make-proto func ctx-stx)))))
                    (sort-category category))))
            ops))))))


(define (prim-op-defns lib ctx-stx not-in)
  (make-splice
   (let ([ops (map (lambda (cat)
                     (cons (car cat)
                           (list (cdr cat))))
                   (lookup-documentation lib 'procedures))]
         [not-in-ns (map (lambda (not-in-mod)
                           (let ([ns (make-base-namespace)])
                             (parameterize ([current-namespace ns])
                               (namespace-require `(for-label ,not-in-mod)))
                             ns))
                         not-in)])
     (apply
      append
      (map (lambda (category)
             (cons
              (subsection #:tag-prefix (format "~a" lib) (car category))
              (filter values
                      (map
                       (lambda (func)
                         (let ([id (datum->syntax ctx-stx (car func))])
                           (and (not (ormap
                                      (lambda (ns)
                                        (free-label-identifier=?
                                         id
                                         (parameterize ([current-namespace ns])
                                           (namespace-syntax-introduce (datum->syntax #f (car func))))))
                                      not-in-ns))
                                (let ([desc-strs (cddr func)])
3                                  (defthing/proc
                                    id
                                    (to-paragraph (typeset-type (cadr func)))
                                    desc-strs)))))
                       (sort-category category)))))
           ops)))))

