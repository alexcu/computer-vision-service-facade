# frozen_string_literal: true

require 'rufus-scheduler'

class String
  def integer?
    to_i.to_s == self
  end

  def float?
    to_f.to_s == self
  end

  def cronline?
    Rufus::Scheduler::CronLine.new(self)
    true
  rescue ArgumentError
    false
  end
end
