module Echolink
  KEYWORD_REGEX = /\becho\s*link\b/i
  NODE_REGEX = /(?<!\d)(\d{4,7})(?!\d)/
  STATION_REGEX = /\b([A-Z0-9]{1,3}\d[A-Z0-9]{1,4}-(?:R|L))\b/i
  SEGMENT_SPLIT_REGEX = /[\r\n;]+|(?<=[.!?])\s+/
  SERVICE_BOUNDARY_REGEX = /\b(?:allstar|hams?\s+over\s+ip|wires[\s-]*x|dmr|ysf|fusion)\b/i

  module_function

  def parse_frequency(text)
    parse_with_keyword(text, source: 'frequency')
  end

  def parse_message(text)
    parse_with_keyword(text, source: 'message')
  end

  def parse_with_keyword(text, source:)
    text = text.to_s
    text.split(SEGMENT_SPLIT_REGEX).each do |segment|
      keyword_match = segment.match(KEYWORD_REGEX)
      next unless keyword_match

      suffix = segment[keyword_match.end(0)..].to_s
      suffix = suffix.split(SERVICE_BOUNDARY_REGEX, 2).first.to_s

      payload = {}
      station = extract_station(suffix)
      node = extract_node(suffix)
      payload['station'] = station if station
      payload['node'] = node if node
      if payload.any?
        payload['source'] = source
        return payload
      end
    end

    nil
  end
  private_class_method :parse_with_keyword

  def extract_node(text)
    text.to_s.match(NODE_REGEX)&.captures&.first
  end
  private_class_method :extract_node

  def extract_station(text)
    text.to_s.match(STATION_REGEX)&.captures&.first&.upcase
  end
  private_class_method :extract_station
end
