module Tables
  class IgnoredCanonicalNetSuggestion < ActiveRecord::Base
    validates :signature, presence: true, uniqueness: true
  end
end
