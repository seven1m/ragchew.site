# frozen_string_literal: true

require "spec_helper"

RSpec.describe Qrz do
  it "keeps the QRZ session out of request logs" do
    stub_request(:get, %r{https://xmldata\.qrz\.com/xml/current/}).to_return(
      status: 200,
      body: "<QRZDatabase/>"
    )

    expect {
      Qrz.call(s: "private-session", callsign: "K1ABC")
    }.to output(
      "GET https://xmldata.qrz.com/xml/current/?s=***;callsign=K1ABC;agent=https%3A%2F%2Fragchew.site\n"
    ).to_stdout
  end
end
