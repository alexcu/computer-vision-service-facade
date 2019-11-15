# frozen_string_literal: true

require 'rufus-scheduler'
require 'uri'

class String
  def integer?
    to_i.to_s == self
  end

  def float?
    Float(self)
    true
  rescue ArgumentError
    false
  end

  def cronline?
    !Rufus::Scheduler.parse_cron(self, no_error: true).nil?
  end

  def uri?
    self =~ URI::DEFAULT_PARSER.make_regexp
  end
end
