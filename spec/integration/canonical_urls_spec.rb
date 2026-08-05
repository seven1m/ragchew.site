# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe 'canonical URLs' do
  it 'uses the ragchew.site URL without query parameters' do
    get '/about?source=search'

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include(
      '<link rel="canonical" href="https://ragchew.site/about">'
    )
  end

  it 'encodes spaces with plus signs on net pages' do
    get '/net/Example%20Net'

    expect(last_response.status).to eq(404)
    expect(last_response.body).to include(
      '<link rel="canonical" href="https://ragchew.site/net/Example+Net">'
    )
  end

  it 'uses the canonical net name for an alias URL' do
    canonical_net = Tables::CanonicalNet.create!(canonical_name: 'Example Canonical Net')
    Tables::ClosedNet.create!(
      canonical_net:,
      name: 'Example Alias',
      frequency: '146.52',
      mode: 'FM',
      band: '2m',
      started_at: 1.hour.ago,
      ended_at: Time.now,
      host: 'www.netlogger.org',
      checkin_count: 0,
      message_count: 0,
      monitor_count: 0
    )

    get '/net/Example%20Alias'

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include(
      '<link rel="canonical" href="https://ragchew.site/net/Example+Canonical+Net">'
    )
  end

  it 'leaves the ragchew.app landing page independently indexable' do
    header 'Host', 'ragchew.app'
    get '/'

    expect(last_response.status).to eq(200)
    expect(last_response.body).not_to include('rel="canonical"')
  end
end
