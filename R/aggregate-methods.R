### =========================================================================
### "aggregate" methods
### -------------------------------------------------------------------------
###
### This is messy and broken! E.g.
###
###   aggregate(DataFrame(state.x77), FUN=mean, start=1:20, width=10)
###
### doesn't work as expected. Or:
###
###   aggregate(Rle(2:-2, 5:9), FUN=mean, start=1:20, width=17)
###
### doesn't give the same result as:
###
###   aggregate(rep(2:-2, 5:9), FUN=mean, start=1:20, width=17)
###
### See also the FIXME note down below (the one preceding the definition of
### the method for vector) for more mess.
###
### FIXME: Fix the aggregate() mess. Before fixing, it would be good to
### simplify by getting rid of the 'frequency' and 'delta' arguments.
### Then the 'start', 'end', and 'width' arguments wouldn't be needed
### anymore because the user can aggregate by range by passing
### IRanges(start, end, width) to 'by'. After removing these arguments,
### the remaining arguments would be as in stats:::aggregate.data.frame.
### Finally make sure that, when 'by' is not an IntegerRanges, the "aggregate"
### method for vector objects behaves exactly like stats:::aggregate.data.frame
### (the easiest way would be to delegate to it).
###
### A nice extension would be to have 'by' accept an IntegerList object, not
### just an IntegerRanges (which is a special case of IntegerList), to let the
### user specify the subsets of 'x'. When 'by' is an IntegerList, aggregate()
### would be equivalent to:
###
###   sapply(seq_along(by),
###          function(i) FUN(x[by[[i]]], ...), simplify=simplify)
###
### This could be how it is implemented, except for the common use case where
### 'by' is an IntegerRanges (needs special treatment in order to remain as
### fast as it is at the moment). This could even be extended to 'by' being a
### List (e.g. CharacterList, RleList, etc...)
###
### Other options (non-exclusive) to explore:
###
### (a) aggregateByRanges() new generic (should go in IRanges). aggregate()
###     would simply delegate to it when 'by' is an IntegerRanges object (but
###     that means that the "aggregate" methods should also go in IRanges).
###
### (b) lapply/sapply on Views objects (but only works if Views(x, ...)
###     works and views can only be created on a few specific types of
###     objects).
###  


setMethod("aggregate", "matrix", stats:::aggregate.default)
setMethod("aggregate", "data.frame", stats:::aggregate.data.frame)
setMethod("aggregate", "ts", stats:::aggregate.ts)

### S3/S4 combo for aggregate.Vector
aggregate.Vector <- function(x, by, FUN, start=NULL, end=NULL, width=NULL,
                             frequency=NULL, delta=NULL, ..., simplify=TRUE)
{
    aggregate(x, by, FUN, start, end, width, frequency, delta, ...,
              simplify=simplify)
}

.aggregate.Vector <- function(x, by, FUN, start=NULL, end=NULL, width=NULL,
                              frequency=NULL, delta=NULL, ..., simplify=TRUE)
{
    if (missing(FUN)) {
        return(aggregateWithDots(x, by, ...))
    } else if (!missing(by)) {
        if (is.list(by)) {
            ans <- aggregate(as.data.frame(x), by=by, FUN=FUN, ...,
                             simplify=simplify)
            return(DataFrame(ans))
        } else if (is(by, "formula")) {
            ans <- aggregate(by, as.env(x, environment(by), tform=decode),
                             FUN=FUN, ...)
            return(DataFrame(ans))
        }
        start <- structure(start(by), names=names(by))
        end <- end(by)
    } else {
        if (!is.null(width)) {
            if (is.null(start))
                start <- end - width + 1L
            else if (is.null(end))
                end <- start + width - 1L
        }
        ## Unlike as.integer(), as( , "integer") propagates the names.
        start <- as(start, "integer")
        end <- as(end, "integer")
    }
    FUN <- match.fun(FUN)
    if (length(start) != length(end))
        stop("'start', 'end', and 'width' arguments have unequal length")
    n <- length(start)
    if (!is.null(names(start)))
        indices <- structure(seq_len(n), names = names(start))
    else
        indices <- structure(seq_len(n), names = names(end))
    if (is.null(frequency) && is.null(delta)) {
        sapply(indices, function(i)
               FUN(Vector_window(x, start = start[i], end = end[i]), ...),
               simplify = simplify)
    } else {
        frequency <- rep(frequency, length.out = n)
        delta <- rep(delta, length.out = n)
        sapply(indices, function(i)
               FUN(window(x, start = start[i], end = end[i],
                   frequency = frequency[i], delta = delta[i]),
                   ...),
               simplify = simplify)
    }
}
setMethod("aggregate", "Vector", .aggregate.Vector)

.aggregate.Rle <- function(x, by, FUN, start=NULL, end=NULL, width=NULL,
                          frequency=NULL, delta=NULL, ..., simplify=TRUE)
{
    FUN <- match.fun(FUN)
    if (!missing(by)) {
        start <- structure(start(by), names=names(by))
        end <- end(by)
    } else {
        if (!is.null(width)) {
            if (is.null(start))
                start <- end - width + 1L
            else if (is.null(end))
                end <- start + width - 1L
        }
        start <- as(start, "integer")
        end <- as(end, "integer")
    }
    if (length(start) != length(end))
        stop("'start', 'end', and 'width' arguments have unequal length")
    n <- length(start)
    if (!is.null(names(start)))
        indices <- structure(seq_len(n), names = names(start))
    else
        indices <- structure(seq_len(n), names = names(end))
    if (is.null(frequency) && is.null(delta)) {
        width <- end - start + 1L
        rle_list <- extract_ranges_from_Rle(x, start, width, as.list=TRUE)
        names(rle_list) <- names(indices)
        sapply(rle_list, FUN, ..., simplify = simplify)
    } else {
        frequency <- rep(frequency, length.out = n)
        delta <- rep(delta, length.out = n)
        sapply(indices,
               function(i)
               FUN(window(x, start = start[i], end = end[i],
                          frequency = frequency[i], delta = delta[i]),
                   ...),
               simplify = simplify)
    }
}
setMethod("aggregate", "Rle", .aggregate.Rle)

.aggregate.List <- function(x, by, FUN, start=NULL, end=NULL, width=NULL,
                           frequency=NULL, delta=NULL, ..., simplify=TRUE)
{
    if (missing(by)
     || !requireNamespace("IRanges", quietly=TRUE)
     || !is(by, "IntegerRangesList")) {
        ans <- callNextMethod()
        return(ans)
    }
    if (length(x) != length(by))
        stop("for IntegerRanges 'by', 'length(x) != length(by)'")
    y <- as.list(x)
    result <- lapply(structure(seq_len(length(x)), names = names(x)),
                     function(i)
                         aggregate(y[[i]], by = by[[i]], FUN = FUN,
                                   frequency = frequency, delta = delta,
                                   ..., simplify = simplify))
    as(result, "List")
}
setMethod("aggregate", "List", .aggregate.List)

ModelFrame <- function(formula, x) {
    if (length(formula) != 2L) 
        stop("'formula' must not have a left side")
    DataFrame(formulaValues(x, formula))
}

aggregateWithDots <- function(x, by, FUN, ..., drop = TRUE) {
    stopifnot(isTRUEorFALSE(drop))

    endomorphism <- FALSE
    if (missing(by)) {
        if (is(x, "List") && !is(x, "DataFrame") && !is(x, "Ranges")) {
            by <- IRanges::PartitioningByEnd(x)
            x <- unlist(x, use.names=FALSE)
        } else {
            endomorphism <- TRUE
            by <- x
        }
    }

    if (is(by, "IntegerList") && !is(by, "Ranges")) {
        by <- IRanges::ManyToManyGrouping(by, nobj=NROW(x))
    }
    
    if (is(by, "formula")) {
        by <- ModelFrame(by, x)
    } else if (is.list(by) || is(by, "DataFrame")) {
        by <- IRanges::FactorList(by, compress=FALSE)
    }
    
    by <- as(by, "Grouping", strict=FALSE)
    if (IRanges::nobj(by) != NROW(x)) {
        stop("'by' does not have the same number of objects as 'x'")
    }

    if (drop) {
        by <- by[lengths(by) > 0L]
    }
    
    by <- unname(by)
    
    prenvs <- top_prenv_dots(...)
    exprs <- substitute(list(...))[-1L]
    envs <- lapply(prenvs, function(p) {
        as.env(x, p, tform = function(col) IRanges::extractList(col, by))
    })
    stats <- DataFrame(mapply(safeEval, exprs, envs, SIMPLIFY=FALSE))

    if (endomorphism && !is(x, "DataFrame")) {
        ans <- x[end(IRanges::PartitioningByEnd(by))]
        mcols(by) <- NULL
        mcols(ans) <- DataFrame(grouping = by, stats)
    } else {
        ans <- DataFrame(by, stats)
        colnames(ans)[1L] <- "grouping"
    }
    ans
}
