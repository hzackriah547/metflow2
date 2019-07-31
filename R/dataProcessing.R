#' @title doxcms
#' @description Raw MS data processing using xcms.
#' @author Xiaotao Shen
#' \email{shenxt1990@@163.com}
#' @param path Work directory.
#' @param polarity The polarity of data, "positive"or "negative".
#' @param ppm see xcms.
#' @param peakwidth See xcms.
#' @param snthresh See xcms.
#' @param mzdiff See xcms.
#' @param noise See xcms.
#' @param threads Number of threads.
#' @param output.tic Output TIC plot or not.
#' @param output.bpc Output BPC plot or not.
#' @param output.rt.correction.plot Output rt correction plot or not.
#' @param min.fraction See xcms.
#' @param fill.peaks Fill peaks NA or not.
#' @return Peak table.
#' @export

processData <- function(path = ".",
                        polarity = c("positive", "negative"),
                        ppm = 15,
                        peakwidth = c(5, 30),
                        snthresh = 10,
                        mzdiff = -0.001,
                        noise = 500,
                        threads = 4,
                        output.tic = TRUE,
                        output.bpc = TRUE,
                        output.rt.correction.plot = TRUE,
                        min.fraction = 0.8,
                        fill.peaks = FALSE) {
  output.path <- file.path(path, "Result")
  dir.create(output.path)
  
  ##paramters
  parameters <- list(
    path = path,
    polarity = polarity,
    ppm = ppm,
    peakwidth = peakwidth,
    snthresh = peakwidth,
    mzdiff = mzdiff,
    noise = noise,
    threads = threads,
    output.tic = TRUE,
    output.bpc = TRUE,
    output.rt.correction.plot = TRUE,
    min.fraction = 0.8,
    fill.peaks = FALSE
  )
  save(parameters, file = file.path(output.path, "parameters"))
  
  ##peak detection
  f.in <- list.files(path = path,
                     pattern = '\\.(mz[X]{0,1}ML|cdf)',
                     recursive = TRUE)
  
  sample_group <-
    unlist(lapply(stringr::str_split(string = f.in, pattern = "/"), function(x) {
      x[1]
    }))
  
  pd <-
    data.frame(
      sample_name = sub(
        basename(f.in),
        pattern = ".mzXML",
        replacement = "",
        fixed = TRUE
      ),
      sample_group = sample_group,
      stringsAsFactors = FALSE
    )
  
  cat("Reading raw data, it will take a while...\n")
  requireNamespace(xcms)
  if (any(dir(file.path(path, "Result")) == "raw_data")) {
    load(file.path(path, "Result/raw_data"))
  } else{
    raw_data <- MSnbase::readMSData(
      files = f.in,
      pdata = new("NAnnotatedDataFrame", pd),
      mode = "onDisk"
    )
    
    save(raw_data,
         file = file.path(output.path, "raw_data"),
         compress = "xz")
  }
  
  #----------------------------------------------------------------------------
  cat("Peak detecting...\n")
  ###peak detection
  cwp <- xcms::CentWaveParam(
    ppm = ppm,
    peakwidth = peakwidth,
    snthresh = snthresh,
    mzdiff = mzdiff,
    noise = noise
  )
  
  if (any(dir(file.path(path, "Result")) == "xdata")) {
    load(file.path(path, "Result/xdata"))
  } else{
    xdata <- xcms::findChromPeaks(raw_data,
                                  param = cwp,
                                  BPPARAM = BiocParallel::SnowParam(workers = threads))
    
    save(xdata,
         file = file.path(output.path, "xdata"),
         compress = "xz")
  }
  
  cat("Correcting rentention time...\n")
  
  if (any(dir(file.path(path, "Result")) == "xdata2")) {
    load(file.path(path, "Result/xdata2"))
  } else{
    xdata2 <- try(xcms::adjustRtime(xdata,
                                    param = xcms::ObiwarpParam(binSize = 0.6)),
                  silent = TRUE)
  }
  
  if (class(xdata2) == "try-error") {
    xdata2 <- xdata
  } else{
    ## Plot also the difference of adjusted to raw retention time.
    if (output.rt.correction.plot) {
      cat("Drawing RT correction plot...\n")
      rt.correction.plot <- plotAdjustedRT(object = xdata2)
      save(
        rt.correction.plot,
        file = file.path(output.path, "rt.correction.plot"),
        compress = "xz"
      )
      ggplot2::ggsave(
        filename = file.path(output.path, "RT correction plot.png"),
        plot = rt.correction.plot,
        width = 20,
        height = 7
      )
      rm(list = c("rt.correction.plot"))
    }
  }
  
  save(xdata2,
       file = file.path(output.path, "xdata2"),
       compress = "xz")
  
  ###TIC
  if (output.tic) {
    cat("Drawing TIC plot...\n")
    tic.plot <- xcms::chromatogram(object = xdata2,
                                   aggregationFun = "sum")
    ## Define colors for different groups
    group_colors <-
      paste0(RColorBrewer::brewer.pal(9, "Set1")[1:length(unique(sample_group))], "60")
    names(group_colors) <- unique(sample_group)
    ## Plot all chromatograms.
    save(tic.plot,
         file = file.path(output.path, "tic.plot"),
         compress = "xz")
    plot <- chromatogramPlot(object = tic.plot, title = "TIC")
    ggplot2::ggsave(
      filename = file.path(output.path, "TIC.png"),
      plot = plot,
      width = 20,
      height = 7
    )
    rm(list = c("plot", "tic.plot"))
  }
  
  ###BPC
  if (output.bpc) {
    cat("Drawing BPC plot...\n")
    bpc.plot <- xcms::chromatogram(object = xdata2,
                                   aggregationFun = "max")
    ## Define colors for different groups
    group_colors <-
      paste0(RColorBrewer::brewer.pal(9, "Set1")[1:length(unique(sample_group))], "60")
    names(group_colors) <- unique(sample_group)
    ## Plot all chromatograms.
    save(bpc.plot,
         file = file.path(output.path, "bpc.plot"),
         compress = "xz")
    plot <- chromatogramPlot(object = bpc.plot, title = "BPC")
    ggplot2::ggsave(
      filename = file.path(output.path, "BPC.png"),
      plot = plot,
      width = 20,
      height = 7
    )
    rm(list = c("plot", "bpc.plot"))
  }
  
  ## Perform the correspondence
  cat("Group peaks across samples...\n")
  pdp <- xcms::PeakDensityParam(
    sampleGroups = xdata2$sample_group,
    minFraction = min.fraction,
    bw = 20
  )
  xdata2 <- xcms::groupChromPeaks(xdata2, param = pdp)
  
  if (fill.peaks) {
    ## Filling missing peaks using default settings. Alternatively we could
    ## pass a FillChromPeaksParam object to the method.
    xdata2 <- xcms::fillChromPeaks(xdata2)
  }
  
  cat("Outputting peak table...\n")
  ##output peak table
  values <- xcms::featureValues(xdata2, value = "into")
  definition <- xcms::featureDefinitions(object = xdata2)
  definition <- definition[, -ncol(definition)]
  peak.name <- xcms::groupnames(xdata2)
  
  peak.table <- data.frame(peak.name = peak.name,
                           definition,
                           values,
                           stringsAsFactors = FALSE)
  rownames(peak.table) <- NULL
  colnames(peak.table) <-
    stringr::str_replace(
      string = colnames(peak.table),
      pattern = "\\.mz[X]{0,1}ML",
      replacement = ""
    )
  readr::write_csv(peak.table, path = file.path(output.path, "Peak.table.csv"))
  cat("All is done!\n")
}


#' @title chromatogramPlot
#' @description Draw TIC or BPC.
#' @author Xiaotao Shen
#' \email{shenxt1990@@163.com}
#' @param object Object for tic.plot or bpc.plot.
#' @param title.size Font size of title..
#' @param lab.size Font size of lab title.
#' @param axis.text.size Font size of axis text.
#' @param alpha alpha.
#' @param title Title of the plot..
#' @return A ggplot2 object.
#' @export

setGeneric(
  name = "chromatogramPlot",
  def = function(object,
                 title.size = 15,
                 lab.size = 15,
                 axis.text.size = 15,
                 alpha = 0.5,
                 title = "") {
    options(warn = -1)
    info <- object@phenoData@data
    data <- object@.Data
    rm(list = c("object"))
    data <- apply(data, 2, function(x) {
      x <- x[[1]]
      x <-
        data.frame(
          "mz" = x@rtime,
          "intensity" = x@intensity,
          stringsAsFactors = FALSE
        )
      list(x)
    })
    
    data <- lapply(data, function(x) {
      x[[1]]
    })
    
    data <- mapply(
      FUN = function(x, y, z) {
        x <- data.frame(
          x,
          "group" = y,
          "sample" = z,
          stringsAsFactors = FALSE
        )
        list(x)
      },
      x = data,
      y = info[, 2],
      z = info[, 1]
    )
    
    # data <- lapply(data, function(x){
    #   x <- plyr::dlply(.data = x, .variables = plyr::.(sample))
    # })
    
    data <- do.call(rbind, args = data)
    
    # data <- plyr::dlply(.data = data, .variables = plyr::.(sample))
    
    plot <- ggplot2::ggplot(data = data,
                            ggplot2::aes(x = mz, y = intensity)) +
      ggplot2::geom_line(
        data = data,
        mapping = ggplot2::aes(colour = group, shape = sample),
        alpha = alpha
      ) +
      ggplot2::theme_bw() +
      ggplot2::labs(x = "Mass to charge ratio (m/z)", y = "Intensity", title = title) +
      ggplot2::theme(
        plot.title = ggplot2::element_text(
          color = "black",
          size = title.size,
          face = "plain",
          hjust = 0.5
        ),
        axis.title = ggplot2::element_text(
          color = "black",
          size = lab.size,
          face = "plain"
        ),
        axis.text = ggplot2::element_text(
          color = "black",
          size = axis.text.size,
          face = "plain"
        )
      )
  }
)


setGeneric(
  name = "plotAdjustedRT",
  def = function(object,
                 title.size = 15,
                 lab.size = 15,
                 axis.text.size = 15) {
    diffRt <- xcms::rtime(object, adjusted = TRUE) - xcms::rtime(object,
                                                                 adjusted = FALSE)
    diffRt <- split(diffRt, MSnbase::fromFile(object))
    xRt <- xcms::rtime(object,
                       adjusted = TRUE,
                       bySample = TRUE)
    
    sample_name <- object@phenoData@data$sample_name
    sample_group <- object@phenoData@data$sample_group
    
    diffRt <- mapply(
      FUN = function(x, y) {
        list(data.frame(x, y, stringsAsFactors = FALSE))
      },
      x = diffRt,
      y = sample_name
    )
    
    xRt <- mapply(
      FUN = function(x, y) {
        list(data.frame(x, y, stringsAsFactors = FALSE))
      },
      x = xRt,
      y = sample_name
    )
    
    diffRt <- do.call(what = rbind, args = diffRt)
    xRt <- do.call(rbind, xRt)
    
    temp.data <-
      data.frame(xRt, diffRt, stringsAsFactors = FALSE)
    
    colnames(temp.data) <-
      c("rt", "sample.name", "diffRT", "sample.name2")
    rm(list = c("object", "xRt", "diffRt"))
    
    plot <-
      ggplot2::ggplot(data = temp.data, ggplot2::aes(x = rt, y = diffRT)) +
      ggplot2::geom_line(data = temp.data, ggplot2::aes(color = sample.name)) +
      ggplot2::theme_bw() +
      ggplot2::labs(x = "Retention time (second)", y = "RT deviation (second)") +
      ggplot2::theme(
        legend.position = "none",
        axis.title = ggplot2::element_text(
          color = "black",
          size = lab.size,
          face = "plain"
        ),
        axis.text = ggplot2::element_text(
          color = "black",
          size = axis.text.size,
          face = "plain"
        )
      )
    plot
  }
)