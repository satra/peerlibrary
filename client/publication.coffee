@SCALE = 1.25

shownPublication = null

class @Publication extends @Publication
  constructor: (args...) ->
    super args...

    @_pages = null
    @_annotator = new Annotator

  _viewport: (page) =>
    scale = SCALE
    page.page.getViewport scale

  _progressCallback: (progressData) =>
    # Maybe this instance has been destroyed in meantime
    return if @_pages is null

    @_progressData = progressData if progressData

    documentHalf = _.min [(@_progressData.loaded / @_progressData.total) / 2, 0.5]
    pagesHalf = if @_pdf then (@_pagesDone / @_pdf.numPages) / 2 else 0

    Session.set 'currentPublicationProgress', documentHalf + pagesHalf

  show: =>
    console.debug "Showing publication #{ @_id }"

    assert.strictEqual @_pages, null

    @_pagesDone = 0
    @_pages = []

    PDFJS.getDocument(@url(), null, null, @_progressCallback).then (@_pdf) =>
      # Maybe this instance has been destroyed in meantime
      return if @_pages is null

      # To make sure we are starting with empty slate
      $('#viewer .display-wrapper').empty()

      for pageNumber in [1..@_pdf.numPages]
        Session.set "currentPublicationPageRendered_#{ pageNumber }", false

        $canvas = $('<canvas/>').addClass('display-canvas').addClass('display-canvas-loading').data('page-number', pageNumber)
        $loading = $('<div/>').addClass('loading').text("Page #{ pageNumber }")
        $('<div/>').addClass(
          'display-page'
        ).attr(
          id: "display-page-#{ pageNumber }"
          unselectable: 'on' # For Opera
        ).on(
          'selectstart', false # Trying hard to disable default selection
        ).append($canvas).append($loading).appendTo('#viewer .display-wrapper')

        do (pageNumber) =>
          @_pdf.getPage(pageNumber).then (page) =>
            # Maybe this instance has been destroyed in meantime
            return if @_pages is null

            assert.equal pageNumber, page.pageNumber

            viewport = @_viewport
              page: page # Dummy page object

            $displayPage = $("#display-page-#{ page.pageNumber }")
            $canvas = $displayPage.find('canvas')
            $canvas.removeClass('display-canvas-loading').attr
              height: viewport.height
              width: viewport.width
            $displayPage.css
              height: viewport.height
              width: viewport.width

            @_pages[pageNumber - 1] =
              pageNumber: pageNumber
              page: page
              rendering: false
            @_pagesDone++

            @_progressCallback()

            # Check if new page should be maybe rendered?
            @checkRender()

          , (args...) =>
            # TODO: Handle errors better (call destroy?)
            console.error "Error getting page #{ pageNumber }", args...

      $(window).on 'scroll.publication', @checkRender
      $(window).on 'resize.publication', @checkRender

    , (args...) =>
      # TODO: Handle errors better (call destroy?)
      console.error "Error showing #{ @_id }", args...

  checkRender: =>
    for page in @_pages or []
      continue if page.rendering

      $canvas = $("#display-page-#{ page.pageNumber } canvas")

      canvasTop = $canvas.offset().top
      canvasBottom = canvasTop + $canvas.height()
      # Add 100px so that we start rendering early
      if canvasTop - 100 <= $(window).scrollTop() + $(window).height() and canvasBottom + 100 >= $(window).scrollTop()
        @renderPage page

  destroy: =>
    console.debug "Destroying publication #{ @_id }"

    shownPublication = null

    pages = @_pages or []
    @_pages = null # To remove references to pdf.js elements to allow cleanup, and as soon as possible as this disables other callbacks

    $(window).off 'scroll.publication'
    $(window).off 'resize.publication'

    for page in pages
      page.page.destroy()
    @_pdf.destroy() if @_pdf

    # To make sure it is cleaned up
    @_annotator = null

  renderPage: (page) =>
    return if page.rendering
    page.rendering = true

    Session.set "currentPublicationPageRendered_#{ page.page.pageNumber }", true

    console.debug "Rendering page #{ page.page.pageNumber }"

    @_annotator.setPage page.page

    page.page.getTextContent().then (textContent) =>
      # Maybe this instance has been destroyed in meantime
      return if @_pages is null

      @_annotator.setTextContent page.pageNumber, textContent

      $displayPage = $("#display-page-#{ page.pageNumber }")
      $canvas = $displayPage.find('canvas')

      # Redo canvas resize to make sure it is the right size
      # It seems sometimes already resized canvases are being deleted and replaced with initial versions
      viewport = @_viewport page
      $canvas.attr
        height: viewport.height
        width: viewport.width
      $displayPage.css
        height: viewport.height
        width: viewport.width

      renderContext =
        canvasContext: $canvas.get(0).getContext '2d'
        textLayer: @_annotator.textLayer page.pageNumber
        imageLayer: @_annotator.imageLayer page.pageNumber
        viewport: @_viewport page

      page.page.render(renderContext).then =>
        # Maybe this instance has been destroyed in meantime
        return if @_pages is null

        console.debug "Rendering page #{ page.page.pageNumber } complete"

        $("#display-page-#{ page.pageNumber } .loading").hide()

      , (args...) =>
        # TODO: Handle errors better (call destroy?)
        console.error "Error rendering page #{ page.page.pageNumber }", args...

    , (args...) =>
      # TODO: Handle errors better (call destroy?)
      console.error "Error rendering page #{ page.page.pageNumber }", args...

  # Fields needed when showing (rendering) the publication: those which are needed for PDF URL to be available and slug
  # TODO: Verify that it works after support for filtering fields on the client will be released in Meteor
  @SHOW_FIELDS: ->
    fields:
      foreignId: 1
      source: 1
      slug: 1

Deps.autorun ->
  if Session.get 'currentPublicationId'
    Meteor.subscribe 'publications-by-id', Session.get 'currentPublicationId'
    Meteor.subscribe 'annotations-by-publication', Session.get 'currentPublicationId'

Deps.autorun ->
  # TODO: Limit only to fields necessary to display publication so that it is not rerun on field changes
  publication = Publications.findOne Session.get('currentPublicationId'), Publication.SHOW_FIELDS()

  return unless publication

  unless Session.equals 'currentPublicationSlug', publication.slug
    Meteor.Router.to Meteor.Router.publicationPath publication._id, publication.slug
    return

  # Maybe we don't yet have whole publication object available
  try
    unless publication.url()
      return
  catch e
    return

  publication.show()
  Deps.onInvalidate publication.destroy

  shownPublication = publication

Template.publication.publication = ->
  Publications.findOne Session.get 'currentPublicationId'

Template.publicationAnnotations.annotations = ->
  Annotations.find
    'publication.id': Session.get 'currentPublicationId'
  ,
    sort: [
      ['locationStart.pageNumber', 'asc']
      ['locationStart.index', 'asc']
      ['locationEnd.pageNumber', 'asc']
      ['locationEnd.index', 'asc']
    ]

Template.publicationAnnotationsItem.events =
  'mouseenter .annotation': (e, template) ->
    unless _.isEqual Session.get('currentAnnotationId'), @_id
      Session.set 'currentAnnotationId', null

    return unless shownPublication

    annotator = shownPublication._annotator

    annotator._activeHighlightStart = @locationStart
    annotator._activeHighlightEnd = @locationEnd

    annotator._showActiveHighlight()

  'mouseleave .annotation': (e, template) ->
    return if _.isEqual Session.get('currentAnnotationId'), @_id

    return unless shownPublication

    shownPublication._annotator._hideActiveHiglight()

  'click .annotation': (e, template) ->
    unless _.isEqual Session.get('currentAnnotationId'), @_id
      Session.set 'currentAnnotationId', @_id

    return unless shownPublication

    annotator = shownPublication._annotator

    annotator._activeHighlightStart = @locationStart
    annotator._activeHighlightEnd = @locationEnd

    annotator._showActiveHighlight()

Template.publicationAnnotationsItem.pageRendered = ->
  Session.get "currentPublicationPageRendered_#{ @locationStart.pageNumber }"

Template.publicationAnnotationsItem.highlighted = ->
  annotationId = Session.get 'currentAnnotationId'

  'highlighted' if @_id is annotationId

Template.publicationAnnotationsItem.top = ->
  return unless Session.get "currentPublicationPageRendered_#{ @locationStart.pageNumber }"

  $pageCanvas = $("#display-page-#{ @locationStart.pageNumber }")

  return unless $pageCanvas.offset()

  $pageCanvas.offset().top - $('.annotations').offset().top + @locationStart.top

Template.publicationAnnotationsItem.rendered = ->
  $(@findAll '.annotation').data
    annotation: @data
