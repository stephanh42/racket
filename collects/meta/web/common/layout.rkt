#lang at-exp s-exp meta/web/html

(require (for-syntax racket/base syntax/name) "utils.rkt" "resources.rkt")

(define-for-syntax (process-contents who layouter stx xs)
  (let loop ([xs xs] [kws '()] [id? #f])
    (syntax-case xs ()
      [(k v . xs) (keyword? (syntax-e #'k))
       (loop #'xs (list* #'v #'k kws) (or id? (eq? '#:id (syntax-e #'k))))]
      [_ (with-syntax ([layouter layouter]
                       [(x ...) (reverse kws)]
                       [(id ...)
                        (if id?
                          '()
                          (let ([name (or (syntax-property stx 'inferred-name)
                                          (syntax-local-name))])
                            (if name (list '#:id `',name) '())))]
                       ;; delay body, allow definitions
                       [body #`(lambda () (text #,@xs))])
           #'(layouter id ... x ... body))])))

;; for plain text files
(define-syntax (plain stx)
  (syntax-case stx () [(_ . xs) (process-contents 'plain #'plain* stx #'xs)]))
(provide plain)
(define (plain* #:id [id #f] #:suffix [suffix #f] #:dir [dir #f]
                #:file
                [file (if (and id suffix)
                        (let ([f (format "~a.~a" (force id) suffix)])
                          (if dir (string-append dir "/" f) f))
                        (error 'plain
                               "missing `#:file', or `#:id' and `#:suffix'"))]
                #:referrer
                [referrer (lambda (url)
                            (error 'plain "no referrer for ~e" file))]
                #:newline [newline? #t]
                . content)
  (resource file
            (file-writer output (list content (and newline? "\n")))
            referrer))

;; page layout function
;; (not providing `page', see `define-pager' below)
(define-syntax (page stx)
  (syntax-case stx () [(_ . xs) (process-contents 'page #'page* stx #'xs)]))
(define (page* #:id [id #f]
               #:dir [dir #f]
               #:file [file (if id
                              (format "~a.html" (force id))
                              (error 'page "missing `#:file' or `#:id'"))]
               #:title [label (if id
                                (let* ([id (->string (force id))]
                                       [id (regexp-replace #rx"^.*/" id "")]
                                       [id (regexp-replace #rx"-" id " ")])
                                  (string-titlecase id))
                                (error 'page "missing `#:file' or `#:title'"))]
               #:link-title [linktitle label]
               #:window-title [wintitle @list{Racket: @label}]
               #:full-width [full-width #f]
               #:extra-headers [headers #f]
               #:extra-body-attrs [body-attrs #f]
               #:resources resources ; see below
               #:referrer [referrer
                           (lambda (url . more)
                             (a href: url (if (null? more) linktitle more)))]
               ;; will be used instead of `this' to determine navbar highlights
               #:part-of [part-of #f]
               content)
  (define (page)
    (let* ([head    (resources 'head wintitle headers)]
           [navbar  (resources 'navbar (or part-of this))]
           [content (list navbar (if full-width
                                   content
                                   (div class: 'bodycontent content)))])
      @xhtml{@head
             @(if body-attrs
                (apply body `(,@body-attrs ,content))
                (body content))}))
  (define this
    (resource (if dir (string-append dir "/" file) file)
              (file-writer output-xml page) referrer))
  this)

(provide set-navbar!)
(define-syntax-rule (set-navbar! pages help)
  (if (unbox navbar-info)
    ;; since generation is delayed, it won't make sense to change the navbar
    (error 'set-navbar! "called twice")
    (set-box! navbar-info (list (lazy pages) (lazy help)))))

(define navbar-info (box #f))
(define (navbar-maker logo)
  (define pages-promise (lazy (car (or (unbox navbar-info)
                                       (error 'navbar "no navbar info set")))))
  (define help-promise (lazy (cadr (unbox navbar-info))))
  (define (middle-text size x)
    (span style: `("font-size: ",size"px; vertical-align: middle;")
          class: 'navtitle
          x))
  (define OPEN
    (list (middle-text 100 "(")
          (middle-text 80 "(")
          (middle-text 60 "(")
          (middle-text 40 nbsp)))
  (define CLOSE
    (list (middle-text 80 "Racket")
          (middle-text 40 nbsp)
          (middle-text 60 ")")
          (middle-text 80 ")")
          (middle-text 100 ")")))
  (define (header-cell logo)
    (td OPEN
        (img src: logo alt: "[logo]"
             style: '("vertical-align: middle; "
                      "margin: 13px 0.25em 0 0; border: 0;"))
        CLOSE))
  (define (links-table this)
    (table width: "100%"
      (tr (map (lambda (nav)
                 (td class: 'navlinkcell
                   (span class: 'navitem
                     (span class: (if (eq? this nav) 'navcurlink 'navlink)
                       nav))))
               (force pages-promise)))))
  (lambda (this)
    (div class: 'navbar
      (div class: 'titlecontent
        (table border: 0 cellspacing: 0 cellpadding: 0 width: "100%"
          (tr (header-cell logo)
              (td class: 'helpiconcell
                  (let ([help (force help-promise)])
                    (span class: 'helpicon (if (eq? this help) nbsp help)))))
          (tr (td colspan: 2 (links-table this))))))))

(define (html-head-maker icon style)
  (define headers
    (list @meta[name: "generator" content: "Racket"]
          @meta[http-equiv: "Content-Type" content: "text/html; charset=utf-8"]
          @link[rel: "icon" href: icon type: "image/ico"]
          @link[rel: "shortcut icon" href: icon]
          style))
  (lambda (title* more-headers) (head @title[title*] headers more-headers)))

(define (make-resources icon logo style)
  (let ([make-head   (html-head-maker icon style)]
        [make-navbar (navbar-maker logo)])
    (lambda (what . more)
      (apply (case what
               [(head)   make-head]
               [(navbar) make-navbar]
               [else (error 'resources "internal error")])
             more))))

;; `define-pager' should be used in each toplevel directory (= each
;; site) to have its own resources (and possibly other customizations).
(provide define-pager)
(define-syntax-rule (define-pager page-id dir)
  (begin (define resources
           (make-resources (make-icon dir) (make-logo dir) (make-style dir)))
         (define-syntax-rule (page-id . xs)
           (page #:resources resources #:dir dir . xs))))