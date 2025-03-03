#' Filter a string to non-null elements
#' @param l A list.
#' @noRd
#' @return A list.
ct <- function(l) Filter(Negate(is.null), l)

#' Get user agent info
#' @noRd
#' @return A string indicating the package version numbers for the curl, crul,
#'   and rredlist R packages.
#' @importFrom utils packageVersion
rredlist_ua <- function() {
  versions <- c(
    paste0("r-curl/", packageVersion("curl")),
    paste0("crul/", packageVersion("crul")),
    sprintf("rOpenSci(rredlist/%s)", packageVersion("rredlist"))
  )
  paste0(versions, collapse = " ")
}

#' Build and handle a GET query of the IUCN API
#'
#' @param path (character) The full API endpoint.
#' @param key (character) An IUCN API token. See [rl_use_iucn()].
#' @param query (list) A list of parameters to include in the GET query.
#' @param ... [Curl options][curl::curl_options()] passed to the GET request via
#'   [HttpClient][crul::HttpClient()].
#'
#' @noRd
#' @return The response of the query as a JSON string.
#' @importFrom crul HttpClient
rr_GET <- function(path, key = NULL, query = list(), ...) {
  # Extract secret API query arguments
  args <- list(...)
  query$latest <- args$latest
  query$scope_code <- args$scope_code
  query$year_published <- args$year_published

  cli <- HttpClient$new(
    url = paste(rr_base(), space(path), sep = "/"),
    opts = list(useragent = rredlist_ua()),
    headers = list(Authorization = check_key(key))
  )
  temp <- cli$get(query = ct(query), ...)
  if (temp$status_code >= 300) {
    if (temp$status_code == 401) {
      stop("Token not valid! (HTTP 401)", call. = FALSE)
    } else if (temp$status_code == 404) {
      stop("No results returned for query. (HTTP 404)", call. = FALSE)
    } else {
      temp$raise_for_status()
    }
  }
  x <- temp$parse("UTF-8")
  err_catcher(x)
  return(x)
}

#' Catch response errors
#' @param x (character) A JSON string representing the response of a GET query.
#' @return If no errors are found in the JSON string, nothing is returned. If
#'   errors are found in the JSON string, an error is thrown.
#' @noRd
#' @importFrom jsonlite fromJSON
err_catcher <- function(x) {
  xx <- fromJSON(x)
  if (any(vapply(c("message", "error"), function(z) z %in% names(xx),
                 logical(1)))) {
    stop(xx[[1]], call. = FALSE)
  }
}

#' Parse a JSON string to a list
#'
#' @param x (character) A JSON string.
#' @param parse (logical) Whether to parse sub-elements of the list to lists
#'   (`FALSE`) or, where possible, to data.frames (`TRUE`). Default:
#'   `TRUE`.
#'
#' @return A list.
#' @noRd
#' @importFrom jsonlite fromJSON
rl_parse <- function(x, parse) {
  fromJSON(x, parse)
}


#' Retrieve a stored API key, if needed
#'
#' @param x (character) An API key as a string. Can also be `NULL`, in which
#'   case the API key will be retrieved from the environmental variable or R
#'   option (in that order).
#'
#' @return A string. If no API key is found, an error is thrown.
#' @noRd
check_key <- function(x) {
  tmp <- if (is.null(x)) Sys.getenv("IUCN_REDLIST_KEY", "") else x
  if (tmp == "") {
    getOption("iucn_redlist_key", stop("need an API key for Red List data",
                                       call. = FALSE))
  } else {
    tmp
  }
}

#' Parse a JSON string to a list
#'
#' @return The base URL for the IUCN API
#' @noRd
rr_base <- function() "https://api.iucnredlist.org/api/v4"

space <- function(x) gsub("\\s", "%20", x)


#' Check that a value inherits the desired class
#'
#' @param x The value to be checked.
#' @param y (character) The name of a class.
#'
#' @return If the check fails, an error is thrown, otherwise, nothing is
#'   returned.
#' @noRd
assert_is <- function(x, y) {
  if (!is.null(x)) {
    if (!inherits(x, y)) {
      stop(deparse(substitute(x)), " must be of class ",
           paste0(y, collapse = ", "), call. = FALSE)
    }
  }
}

#' Check that a value has a desired length
#'
#' @param x The value to be checked.
#' @param n (numeric) The desired length.
#'
#' @return If the check fails, an error is thrown, otherwise, nothing is
#'   returned.
#' @noRd
assert_n <- function(x, n) {
  if (!is.null(x)) {
    if (!length(x) == n) {
      stop(deparse(substitute(x)), " must be length ", n, call. = FALSE)
    }
  }
}

#' Check that a value is not NA
#'
#' @param x The value to be checked.
#'
#' @return If the check fails, an error is thrown, otherwise, nothing is
#'   returned.
#' @noRd
assert_not_na <- function(x) {
  if (!is.null(x)) {
    if (any(is.na(x))) {
      stop(deparse(substitute(x)), " must not be NA", call. = FALSE)
    }
  }
}


#' Combine assessments from multiple pages of a single query
#'
#' @param res A list where each element represents the assessments from a single
#'   page of a multi-page query (such as the output of `page_assessments()`).
#' @param parse (logical) Whether to parse and combine the assessments into a
#'   data.frame (`TRUE`) or keep them as lists (`FALSE`). Default:
#'   `TRUE`.
#' @noRd
#' @return If `parse` is `TRUE`, a data.frame, otherwise, a list.
combine_assessments <- function(res, parse) {
  if (length(res) <= 1) return(rl_parse(res, parse))
  lst <- lapply(res, rl_parse, parse = parse)
  tmp <- lst[[1]]
  assessments <- lapply(lst, "[[", "assessments")
  if (parse) {
    tmp$assessments <- do.call(rbind, assessments)
  } else {
    tmp$assessments <- do.call(c, assessments)
  }
  return(tmp)
}

#' Page through assessments
#'
#' @param path (character) The full API endpoint.
#' @param key (character) An IUCN API token. See [rl_use_iucn()].
#' @param quiet (logical) Whether to suppress progress for multi-page downloads
#'   or not. Default: `FALSE` (that is, give progress). Ignored if `all =
#'   FALSE`.
#' @param ... [Curl options][curl::curl_options()] passed to the GET request via
#'   [HttpClient][crul::HttpClient()].
#'
#' @return A list with each element representing the response of one page of
#'   results.
#' @noRd
#' @importFrom jsonlite fromJSON
page_assessments <- function(path, key, quiet, ...) {
  out <- list()
  done <- FALSE
  page <- 1
  while (!done) {
    tmp <- rr_GET(path, key, query = list(page = page), ...)
    if (length(fromJSON(tmp, FALSE)$assessments) == 0) {
      if (page == 1) out <- tmp else if (page == 2) out <- out[[1]]
      done <- TRUE
    } else {
      if (!quiet) cat(".")
      out[[page]] <- tmp
      page <- page + 1
    }
  }
  if (!quiet && page > 1) cat("\n")
  return(out)
}
