# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Echolink do
  describe '.parse_message' do
    it 'matches a station after an echolink label with punctuation' do
      expect(described_class.parse_message('Echolink: N5XQK-R')).to eq(
        'station' => 'N5XQK-R',
        'source' => 'message'
      )
    end

    it 'matches a node after filler words' do
      expect(described_class.parse_message('echo link node number 657006')).to eq(
        'node' => '657006',
        'source' => 'message'
      )
    end

    it 'does not match a station without echolink context' do
      expect(described_class.parse_message('N5XQK-R is up')).to be_nil
    end

    it 'does not match a node without echolink context' do
      expect(described_class.parse_message('node 657006')).to be_nil
    end

    it 'does not capture an allstar node from a broader message containing echolink details' do
      message = <<~TEXT
        N5XQK Memorial Boredom Breaker Net

        RCWA Repeater: FM frequency 147.090 positive offset (+.600) PL=88.5 (Allstar node 49562; Echolink N5XQK-R.)

        Direct Connections/Links.

        RCWA Allstar node 49562 (24x7)

        Echolink N5XQK-R (24x7).

        Echolink 657006

        Hams Over IP 15018
      TEXT

      expect(described_class.parse_message(message)).to eq(
        'station' => 'N5XQK-R',
        'source' => 'message'
      )
    end
  end

  describe '.parse_frequency' do
    it 'matches a station after an echolink label with punctuation' do
      expect(described_class.parse_frequency('Echolink: N5XQK-R')).to eq(
        'station' => 'N5XQK-R',
        'source' => 'frequency'
      )
    end

    it 'matches a node after filler words' do
      expect(described_class.parse_frequency('echo link node number 657006')).to eq(
        'node' => '657006',
        'source' => 'frequency'
      )
    end
  end
end
