module ReviewDemo
  module_function

  def net
    Tables::Net.find_by(name: APPLE_REVIEW_DEMO_NET_NAME)
  end

  def user
    Tables::User.find_by(call_sign: APPLE_REVIEW_DEMO_CALL_SIGN)
  end

  def create_user!
    review_user = Tables::User.find_or_initialize_by(call_sign: APPLE_REVIEW_DEMO_CALL_SIGN)
    review_user.first_name = 'Review'
    review_user.last_name = 'Demo'
    review_user.test_user = true
    review_user.save!
    review_user
  end

  def recreate_net!
    create_user!
    delete_net!

    review_net = Tables::Net.create!(
      name: APPLE_REVIEW_DEMO_NET_NAME,
      frequency: '146.520',
      mode: 'FM',
      band: '2m',
      net_control: APPLE_REVIEW_DEMO_CALL_SIGN,
      net_logger: APPLE_REVIEW_DEMO_CALL_SIGN,
      started_at: Time.now,
      im_enabled: true,
      update_interval: 30000,
      subscribers: 0,
      host: 'ragchew.site',
      created_by_ragchew: true,
      ragchew_only_testing_net: true
    )

    qrz = QrzAutoSession.new
    review_checkins.each do |seed|
      station = qrz.lookup(seed[:call_sign])
      latitude, longitude = GridSquare.new(station[:grid_square]).to_a

      review_net.checkins.create!(
        num: seed[:num],
        call_sign: station[:call_sign],
        name: [station[:first_name], station[:last_name]].compact.join(' '),
        preferred_name: station[:first_name],
        remarks: seed[:remarks],
        checked_in_at: Time.now,
        grid_square: station[:grid_square],
        street: station[:street],
        city: station[:city],
        state: station[:state],
        zip: station[:zip],
        county: station[:county],
        country: station[:country],
        dxcc: station[:dxcc],
        latitude: latitude,
        longitude: longitude
      )
    end

    ki5zdf = qrz.lookup('KI5ZDF')
    review_net.monitors.create!(
      call_sign: ki5zdf[:call_sign],
      num: 0,
      name: ki5zdf[:first_name],
      version: UserPresenter::NET_LOGGER_FAKE_VERSION,
      status: 'Online',
      blocked: false
    )

    review_net.update!(checkin_count: review_net.checkins.not_blank.count)
    review_net
  end

  def delete_net!
    review_net = net
    return false unless review_net

    Tables::User.where(monitoring_net_id: review_net.id).update_all(monitoring_net_id: nil)
    Tables::User.where(logging_net_id: review_net.id).update_all(logging_net_id: nil)
    review_net.destroy!
    true
  end

  def review_checkins
    [
      { num: 1, call_sign: 'KI5ZDF', remarks: 'NCO' },
      { num: 2, call_sign: 'KI5ZDG', remarks: nil }
    ]
  end
end
