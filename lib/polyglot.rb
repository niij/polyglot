# Jekyll Polyglot v1.1.2
# Fast, painless, open source i18n plugin for Jekyll 3.0 Blogs.
#   author: Samuel Volin (@untra)
#   github: https://github.com/untra/polyglot
#   license: MIT
include Process
module Jekyll
  # Alteration to Jekyll Site class
  # provides aliased methods to direct site.write to output into seperate
  # language folders
  class Site
    attr_reader :default_lang, :languages, :exclude_from_localization
    attr_accessor :file_langs, :active_lang

    def prepare
      @file_langs = {}
      @default_lang = config['default_lang'] || 'en'
      @languages = config['languages'] || ['en']
      @parallel_localization = config['parallel_localization'] || true
      (@keep_files << @languages - [@default_lang]).flatten!
      @exclude_from_localization = config['exclude_from_localization'] || []
      @active_lang = @default_lang
    end

    alias_method :process_orig, :process
    def process
      prepare
      if @parallel_localization
        pids = {}
        languages.each do |lang|
          pids[lang] = fork do
            process_language lang
          end
        end
        Signal.trap('INT') do
          languages.each do |lang|
            puts "Killing #{pids[lang]} : #{lang}"
            kill('INT', pids[lang])
          end
        end
        languages.each do |lang|
          waitpid pids[lang]
          detach pids[lang]
        end
      else
        languages.each do |lang|
          process_language lang
        end
      end
    end

    alias_method :site_payload_orig, :site_payload
    def site_payload
      payload = site_payload_orig
      payload['site']['default_lang'] = default_lang
      payload['site']['languages'] = languages
      payload['site']['active_lang'] = active_lang
      payload
    end

    def process_language(lang)
      @active_lang = lang
      config['active_lang'] = @active_lang
      return process_orig if @active_lang == @default_lang
      process_active_language
    end

    def process_active_language
      @dest = @dest + '/' + @active_lang
      @exclude += config['exclude_from_localization']
      process_orig
    end

    # assigns natural permalinks to documents and prioritizes documents with
    # active_lang languages over others
    def coordinate_documents(docs)
      regex = document_url_regex
      langs = {}
      approved = {}
      docs.each do |doc|
        language = doc.data['lang'] || @default_lang
        url = doc.url.gsub(regex, '/')
        puts url
        doc.data['permalink'] = url
        next if langs[url] == @active_lang
        if langs[url] == @default_lang
          next if language != @active_lang
        end
        approved[url] = doc
        langs[url] = language
      end
      approved.values
    end

    # a regex that matches urls or permalinks with i18n prefixes or suffixes
    # matches /en/foo , .en/foo , foo.en/ and other simmilar default urls
    # made by jekyll when parsing documents without explicitly set permalinks
    def document_url_regex
      regex = ''
      @languages.each do |lang|
        regex += "([\/\.]#{lang}[\/\.])|"
      end
      regex.chomp! '|'
      %r{#{regex}}
    end

    # hook to coordinate blog posts and pages into distinct urls,
    # and remove duplicate multilanguage posts and pages
    Jekyll::Hooks.register :site, :post_read do |site|
      site.posts.docs = coordinate_documents(site.posts.docs)
      site.pages.docs = coordinate_documents(site.pages.docs)
    end
  end

  # Alteration to Jekyll Convertible module
  # provides aliased methods to direct Convertible to skip files for write under
  # certain conditions
  module Convertible
    def lang
      data['lang'] || site.config['default_lang']
    end

    def lang=(str)
      data['lang'] = str
    end

    alias_method :write_orig, :write
    def write(dest)
      path = polypath(dest)
      return if skip?(path)
      output_orig = output.clone
      relativize_urls(site.active_lang)
      write_orig(dest)
      self.output = output_orig
      site.file_langs[path] = lang
    end

    def polypath(dest)
      n = ''
      site.languages.each do |lang|
        n += "(\\\.#{lang}\\/)|"
      end
      n.chomp! '|'
      destination(dest).gsub(%r{#{n}}, '/')
    end

    def skip?(path)
      return false if site.file_langs[path].nil?
      return false if lang == site.active_lang
      if lang == site.default_lang
        return site.file_langs[path] == site.active_lang
      end
      true
    end

    def relativize_urls(lang)
      return if lang == site.default_lang
      output.gsub!(relative_url_regex, "href=\"#{site.baseurl}/#{lang}/" + '\1"')
    end

    def relative_url_regex
      n = ''
      site.exclude.each do |x|
        n += "(?!#{x}\/)"
      end
      # regex that looks for all relative urls except for excluded files
      %r{href=\"#{site.baseurl}\/((?:#{n}[^,'\"\s\/?\.#-]+\.?)*(?:\/[^\]\[\)\(\"\'\s]*)?)\"}
    end
  end

  # Alteration to Jekyll StaticFile
  # provides aliased methods to direct write to skip files
  # excluded from localization
  class StaticFile
    alias_method :write_orig, :write
    def write(dest)
      return false if exclude_from_localization?
      write_orig(dest)
    end

    def exclude_from_localization?
      return false if @site.active_lang == @site.default_lang
      @site.exclude_from_localization.each do |e|
        return true if relative_path[1..-1].start_with?(e)
      end
      false
    end
  end
end