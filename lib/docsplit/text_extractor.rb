module Docsplit

  # Delegates to **pdftotext** and **tesseract** in order to extract text from
  # PDF documents. The `--ocr` and `--no-ocr` flags can be used to force or
  # forbid OCR extraction, but by default the heuristic works like this:
  #
  #  * Check for the presence of fonts in the PDF. If no fonts are detected,
  #    OCR is used automatically.
  #  * Extract the text of each page with **pdftotext**, if the page has less
  #    than 100 bytes of text (a scanned image page, or a page that just
  #    contains a filename and a page number), then add it to the list of
  #    `@pages_to_ocr`.
  #  * Re-OCR each page in the `@pages_to_ocr` list at the end.
  #
  class TextExtractor

    NO_TEXT_DETECTED = /---------\n\Z/

    OCR_FLAGS   = '-density 400x400 -colorspace GRAY'
    MEMORY_ARGS = '-limit memory 256MiB -limit map 512MiB'

    MIN_TEXT_PER_PAGE = 100 # in bytes

    def initialize
      @pages_to_ocr = []
    end

    # Extract text from a list of PDFs.
    def extract(pdfs, opts)
      extract_options opts
      FileUtils.mkdir_p @output unless File.exists?(@output)
      [pdfs].flatten.map do |pdf|
        @pdf_name = File.basename(pdf, File.extname(pdf))
        pages = (@pages == 'all') ? 1..Docsplit.extract_length(pdf) : @pages
        if @force_ocr || (!@forbid_ocr && !contains_text?(pdf))
          extract_from_ocr(pdf, pages)
        else
          extract_from_pdf(pdf, pages)
          if !@forbid_ocr && DEPENDENCIES[:tesseract] && !@pages_to_ocr.empty?
            extract_from_ocr(pdf, @pages_to_ocr)
          end
        end

        get_file_absolute_path(@pdf_name)
      end
    end

    # Does a PDF have any text embedded?
    def contains_text?(pdf)
      fonts = `pdffonts #{ESCAPE[pdf]} 2>&1`
      !fonts.match(NO_TEXT_DETECTED)
    end

    # Extract a page range worth of text from a PDF, directly.
    def extract_from_pdf(pdf, pages)
      return extract_full(pdf) unless pages
      pages.each {|page| extract_page(pdf, page) }
    end

    # Extract a page range worth of text from a PDF via OCR.
    def extract_from_ocr(pdf, pages)
      tempdir = Dir.mktmpdir
      base_path = File.join(@output, @pdf_name)
      escaped_pdf = ESCAPE[pdf]
      psm = @detect_orientation ? "-psm 1" : ""
      if pages
        pages.each do |page|
          tiff = "#{tempdir}/#{@pdf_name}_#{page}.tif"
          escaped_tiff = ESCAPE[tiff]
          file = "#{base_path}_#{page}"
          run "MAGICK_TMPDIR=#{tempdir} OMP_NUM_THREADS=2 gm convert -despeckle +adjoin #{MEMORY_ARGS} #{OCR_FLAGS} #{escaped_pdf}[#{page - 1}] #{escaped_tiff} 2>&1"
          run "tesseract #{escaped_tiff} #{ESCAPE[file]} -l #{@language} #{psm} 2>&1"
          clean_text(file + '.txt') if @clean_ocr
          FileUtils.remove_entry_secure tiff
        end
      else
        tiff = "#{tempdir}/#{@pdf_name}.tif"
        escaped_tiff = ESCAPE[tiff]
        run "MAGICK_TMPDIR=#{tempdir} OMP_NUM_THREADS=2 gm convert -despeckle #{MEMORY_ARGS} #{OCR_FLAGS} #{escaped_pdf} #{escaped_tiff} 2>&1"
        #if the user says don't do orientation detection or the plugin is not installed, set psm to 0
        run "tesseract #{escaped_tiff} #{base_path} -l #{@language} #{psm} 2>&1"
        clean_text(base_path + '.txt') if @clean_ocr
      end
    ensure
      FileUtils.remove_entry_secure tempdir if File.exists?(tempdir)
    end


    private

    def clean_text(file)
      File.open(file, 'r+') do |f|
        text = f.read
        f.truncate(0)
        f.rewind
        f.write(Docsplit.clean_text(text))
      end
    end

    # Run an external process and raise an exception if it fails.
    def run(command)
      result = `#{command}`
      raise ExtractionFailed, result if $? != 0
      result
    end

    # Return absolute path of the pdf file
    def get_file_absolute_path(pdf_name)
      @output + pdf_name
    end

    # Run pdftotext command
    def run_pdftotext(pdf, text_path, options=[])
      options << '-enc UTF-8'
      options << '-layout' if @keep_layout

      run "pdftotext #{options.join(' ')} #{ESCAPE[pdf]} #{ESCAPE[text_path]} 2>&1"
    end

    # Extract the full contents of a pdf as a single file, directly.
    def extract_full(pdf)
      text_path = File.join(@output, "#{@pdf_name}.txt")
      run_pdftotext pdf, text_path
    end

    # Extract the contents of a single page of text, directly, adding it to
    # the `@pages_to_ocr` list if the text length is inadequate.
    def extract_page(pdf, page)
      text_path = File.join(@output, "#{@pdf_name}_#{page}.txt")
      run_pdftotext pdf, text_path, ["-f #{page}", "-l #{page}"]

      unless @forbid_ocr
        @pages_to_ocr.push(page) if File.read(text_path).length < MIN_TEXT_PER_PAGE
      end
    end

    def extract_options(options)
      @output             = options[:output] || '.'
      @pages              = options[:pages]
      @force_ocr          = options[:ocr] == true
      @forbid_ocr         = options[:ocr] == false
      @language           = options[:language] || 'eng'
      @clean_ocr          = (!(options[:clean] == false) and @language == 'eng')
      @detect_orientation = ((options[:detect_orientation] != false) and DEPENDENCIES[:osd])
      @keep_layout        = options.fetch(:layout, false)
    end

  end

end
