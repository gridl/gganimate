#' @include transition-manual.R
NULL

#' Transition between different filters
#'
#' This transition allows you to transition between a range of filtering
#' conditions. The conditions are expressed as logical statements and rows in
#' the data will be retained if the statement evaluates to `TRUE`. It is
#' possible to keep filtered data on display by setting `keep = TRUE` which will
#' let data be retained as the result of the exit function. Note that if data is
#' kept the enter function will have no effect.
#'
#' @param transition_length The relative length of the transition. Will be
#' recycled to match the number of states in the data
#' @param filter_length The relative length of the pause at the states. Will be
#' recycled to match the number of states in the data
#' @param ... A number of expression to be evaluated in the context of the layer
#' data, returning a logical vector. If the expressions are named, the name will
#' be available as a frame variable.
#' @param wrap Should the animation *wrap-around*? If `TRUE` the last filter will
#' be transitioned into the first.
#' @param keep Should rows that evaluates to `FALSE` be kept in the data as it
#' looks after exit has been applied
#'
#' @section Label variables:
#' `transition_filter` makes the following variables available for string
#' literal interpretation:
#'
#' - **transitioning** is a booloean indicating whether the frame is part of the
#'   transitioning phase
#' - **previous_filter** The name of the last filter the animation was at
#' - **closest_filter** The name of the filter closest to this frame
#' - **next_filter** The name of the next filter the animation will be part of
#' - **previous_expression** The expression of the last filter the animation was at
#' - **closest_expression** The expression of the filter closest to this frame
#' - **next_expression** The expression of the next filter the animation will be part of
#'
#' @family transitions
#'
#' @export
#' @importFrom rlang quos quos_auto_name
#' @importFrom ggplot2 ggproto
transition_filter <- function(transition_length, filter_length, ..., wrap = TRUE, keep = FALSE) {
  filter_quos <- quos_auto_name(quos(...))
  if (length(filter_quos) < 2) {
    stop('transition_filter requires at least 2 filtering conditions', call. = FALSE)
  }
  ggproto(NULL, TransitionFilter,
    params = list(
      filter_quos = filter_quos,
      transition_length = transition_length,
      filter_length = filter_length,
      wrap = wrap,
      keep = keep
    )
  )
}
#' @rdname gganimate-ggproto
#' @format NULL
#' @usage NULL
#' @export
#' @importFrom ggplot2 ggproto
#' @importFrom stringi stri_match
#' @importFrom tweenr tween_state keep_state
#' @importFrom transformr tween_path tween_polygon tween_sf
#' @importFrom rlang quo_name
TransitionFilter <- ggproto('TransitionFilter', TransitionManual,
  setup_params = function(self, data, params) {
    filters <- assign_filters(data, params$filter_quos)
    transition_length <- rep(params$transition_length, length.out = length(params$filter_quos))
    if (!params$wrap) transition_length[length(transition_length)] <- 0
    filter_length <- rep(params$filter_length, length.out = length(params$filter_quos))
    frames <- distribute_frames(filter_length, transition_length, params$nframes + if (params$wrap) 1 else 0)
    params$row_id <- filters
    params$state_length <- frames$static_length
    params$transition_length <- frames$transition_length
    params$frame_info <- cbind(
      get_frame_info(
        static_levels = names(params$filter_quos),
        static_lengths = params$state_length,
        transition_lengths = params$transition_length,
        nframes = params$nframes,
        static_first = TRUE,
        static_name = 'filter'
      ),
      get_frame_info(
        static_levels = vapply(params$filter_quos, quo_name, character(1)),
        static_lengths = params$state_length,
        transition_lengths = params$transition_length,
        nframes = params$nframes,
        static_first = TRUE,
        static_name = 'expression'
      )
    )
    params$nframes <- nrow(params$frame_info)
    params
  },
  expand_data = function(self, data, type, ease, enter, exit, params, layer_index) {
    Map(function(d, t, en, ex, es) {
      split_panel <- stri_match(d$group, regex = '^(.+)_(.+)$')
      if (is.na(split_panel[1])) return(d)
      d$group <- as.integer(split_panel[, 2])
      if (all(d$group == -1) && t %in% c('point', 'sf')) {
        d$group <- seq_len(nrow(d))
      }
      filter <- strsplit(split_panel[, 3], '-')
      row <- rep(seq_along(filter), lengths(filter))
      filter <- as.integer(unlist(filter))
      present <- filter != 0
      row <- row[present]
      filter <- filter[present]

      filtered_data <- lapply(seq_along(params$filter_quos), function(i) {
        include <- row[filter == i]
        exclude <- setdiff(seq_len(nrow(d)), include)
        d_f <- d
        if (params$keep) {
          exit_data <- ex(d_f[exclude, , drop = FALSE])
          if (is.null(exit_data)) {
            d_f <- d_f[include, , drop = FALSE]
          } else {
            d_f[exclude, ] <- exit_data
          }
        } else {
          d_f <- d_f[include, , drop = FALSE]
        }
        d_f
      })
      all_frames <- filtered_data[[1]]
      for (i in seq_along(filtered_data)) {
        if (params$state_length[i] != 0) {
          all_frames <- keep_state(all_frames, params$state_length[i])
        }
        if (params$transition_length[i] != 0) {
          next_filter <- if (i == length(filtered_data)) filtered_data[[1]] else filtered_data[[i + 1]]
          all_frames <- switch(
            t,
            point = tween_state(all_frames, next_filter, es, params$transition_length[i], 'group', en, ex),
            path = tween_path(all_frames, next_filter, es, params$transition_length[i], 'group', en, ex),
            polygon = tween_polygon(all_frames, next_filter, es, params$transition_length[i], 'group', en, ex),
            sf = tween_sf(all_frames, next_filter, es, params$transition_length[i], 'group', en, ex),
            stop("Unknown layer type", call. = FALSE)
          )
        }
      }
      if (params$wrap) {
        all_frames <- all_frames[all_frames$.frame <= params$nframes, ]
      }
      all_frames$group <- paste0(all_frames$group, '_', all_frames$.frame)
      all_frames$.frame <- NULL
      all_frames
    }, d = data, t = type, en = enter, ex = exit, es = ease)
  }
)

assign_filters <- function(data, filters) {
  lapply(data, function(d) {
    row_filter <- do.call(rbind, lapply(filters, function(f) {
      filter <- safe_eval(f, d)
      filter <- filter %||% rep(TRUE, nrow(d))
      if (!is.logical(filter)) stop('Filters must return a logical vector', call. = FALSE)
      filter
    }))
    if (all(row_filter)) return(numeric(0))
    apply(row_filter, 2, function(x) if (!any(x)) '0' else paste(which(x), collapse = '-'))
  })
}
