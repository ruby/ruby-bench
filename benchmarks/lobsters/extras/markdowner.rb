class Markdowner
  # opts[:allow_images] allows <img> tags

  COMMONMARKER_OPTIONS = {
    parse: { smart: true },
    render: { unsafe: true },
    extension: { tagfilter: true, autolink: true, strikethrough: true }
  }.freeze

  def self.to_html(text, opts = {})
    if text.blank?
      return ""
    end

    # Preprocess @mentions before markdown parsing
    processed_text = preprocess_mentions(text.to_s)

    html = Commonmarker.to_html(processed_text, options: COMMONMARKER_OPTIONS)

    ng = Nokogiri::HTML(html)

    # change <h1>, <h2>, etc. headings to just bold tags
    ng.css("h1, h2, h3, h4, h5, h6").each do |h|
      h.name = "strong"
    end

    # This should happen before adding rel=ugc to all links
    convert_images_to_links(ng) unless opts[:allow_images]

    # make links have rel=ugc
    ng.css("a").each do |h|
      h[:rel] = "ugc" unless (URI.parse(h[:href]).host.nil? rescue false)
    end

    if ng.at_css("body")
      ng.at_css("body").inner_html
    else
      ""
    end
  end

  def self.preprocess_mentions(text)
    text.gsub(/\B(@#{User::VALID_USERNAME})/) do |match|
      user = match[1..-1]
      if User.exists?(username: user)
        "[#{match}](#{Rails.application.root_url}u/#{user})"
      else
        match
      end
    end
  end

  def self.convert_images_to_links(node)
    node.css("img").each do |img|
      link = node.create_element('a')

      link['href'], title, alt = img.attributes
        .values_at('src', 'title', 'alt')
        .map(&:to_s)

      link.content = [title, alt, link['href']].find(&:present?)

      img.replace link
    end
  end
end
