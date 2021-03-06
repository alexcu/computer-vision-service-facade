# frozen_string_literal: true

require 'require_all'
require 'awesome_print'
require 'tty-prompt'

require_all 'src'
require_all 'test'

module Test
  @prompt = TTY::Prompt.new
  def self.prompt
    @prompt
  end
end

def run_test(m)
  puts "*** Running test: #{m}..."
  begin
    Test.send(m)
  rescue StandardError => e
    puts "*** Error!\n#{e}"
    puts "*** Backtrace:\n  #{e.backtrace.join("\n  ")}"
    puts '*** Failed!'
  else
    puts '*** Success!'
  end
end

# Don't commit to the real db!!
Sequel::Model.db.transaction do
  Test.prompt.select('Execute test:') do |mnu|
  [Test.methods - Object.methods].flatten
                                 .select { |s| s.to_s.start_with?('test') }
                                 .each { |m| mnu.choice m, -> { run_test(m) } }
  end
  raise Sequel::Rollback
end
