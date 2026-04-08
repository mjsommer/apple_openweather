# frozen_string_literal: true

require "rails_helper"

RSpec.describe WeatherService, type: :service do
  subject(:service) { described_class.new(address) }

  # Plain doubles — the OpenWeather client uses dynamic module inclusion so
  # instance_double would fail to verify dynamically-added methods like #get.
  let(:mock_client) { double("OpenWeather::Client") } # rubocop:disable RSpec/VerifiedDoubles

  # ---------------------------------------------------------------------------
  # Helpers to build fake API responses
  # ---------------------------------------------------------------------------

  def build_main(temp: 72.0, temp_min: 65.0, temp_max: 79.0, feels_like: 70.0, humidity: 55)
    double("main",
      temp: temp, temp_min: temp_min, temp_max: temp_max,
      feels_like: feels_like, humidity: humidity)
  end

  def build_weather_attrs(description: "clear sky", icon: "01d")
    [ double("weather", description: description, icon: icon) ]
  end

  def build_current(name: "Cupertino", country: "US", **temp_opts)
    double("current_weather",
      name: name,
      sys: double("sys", country: country),
      coord: double("coord", lat: 37.323, lon: -122.032),
      main: build_main(**temp_opts),
      weather: build_weather_attrs)
  end

  # A fake Hourly forecast with N periods, each on the same UTC day unless
  # you pass explicit dt values.
  def build_forecast(periods: 8, dt_base: Time.now.utc)
    list = periods.times.map do |i|
      double("period_#{i}",
        dt: dt_base + (i * 3.hours),
        main: build_main,
        weather: build_weather_attrs)
    end
    double("hourly_forecast", list: list)
  end

  before do
    allow(OpenWeather::Client).to receive(:new).and_return(mock_client)
    # Default stub — individual contexts override as needed.
    allow(OpenWeather::Models::Forecast::Hourly).to receive(:new).and_return(build_forecast)
    allow(mock_client).to receive(:get).and_return({})
  end

  after { Rails.cache.clear }

  # ---------------------------------------------------------------------------
  # .fetch class method
  # ---------------------------------------------------------------------------
  describe ".fetch" do
    let(:address) { "95014" }

    before do
      allow(mock_client).to receive(:current_weather).and_return(build_current)
      allow(mock_client).to receive(:get).and_return({})
    end

    it "delegates to #fetch on a new instance" do
      result = described_class.fetch(address)
      expect(result).to be_a(WeatherService::Result)
    end
  end

  # ---------------------------------------------------------------------------
  # ZIP extraction + API calls
  # ---------------------------------------------------------------------------
  describe "#fetch with a ZIP code in the address" do
    let(:address) { "1 Apple Park Way, Cupertino, CA 95014" }
    let(:current) { build_current(name: "Cupertino", country: "US", temp: 72.5) }

    before do
      allow(mock_client).to receive(:current_weather)
        .with({ zip: "95014,us", units: "imperial" })
        .and_return(current)
    end

    it "returns a successful result" do
      expect(service.fetch.success?).to be true
    end

    it "includes the correct location" do
      expect(service.fetch.data[:location]).to eq("Cupertino, US")
    end

    it "includes the current temperature rounded to integer" do
      expect(service.fetch.data[:current_temp]).to eq(73)
    end

    it "includes feels_like, high, low, and humidity" do
      data = service.fetch.data
      expect(data[:feels_like]).to be_a(Integer)
      expect(data[:temp_high]).to be_a(Integer)
      expect(data[:temp_low]).to be_a(Integer)
      expect(data[:humidity]).to eq(55)
    end

    it "capitalizes the description" do
      expect(service.fetch.data[:description]).to eq("Clear sky")
    end

    it "includes an icon code" do
      expect(service.fetch.data[:icon]).to eq("01d")
    end

    it "includes the zip code in the result" do
      expect(service.fetch.data[:zip]).to eq("95014")
    end

    it "includes up to 5 daily forecasts" do
      expect(service.fetch.data[:daily_forecasts].length).to be <= 5
    end

    it "structures each daily forecast with the expected keys" do
      day = service.fetch.data[:daily_forecasts].first
      expect(day).to include(:date, :temp_high, :temp_low, :description, :icon)
    end
  end

  # ---------------------------------------------------------------------------
  # Caching behaviour
  # ---------------------------------------------------------------------------
  describe "caching" do
    let(:address) { "95014" }

    before do
      allow(mock_client).to receive(:current_weather).and_return(build_current)
    end

    it "is not from cache on the first request" do
      expect(service.fetch.from_cache).to be false
    end

    it "is from cache on subsequent requests for the same ZIP" do
      described_class.fetch(address)           # warm cache
      expect(described_class.fetch(address).from_cache).to be true
    end

    it "only calls the API once when the cache is warm" do
      expect(mock_client).to receive(:current_weather).once
      expect(mock_client).to receive(:get).once

      described_class.fetch(address)
      described_class.fetch(address)
    end

    it "uses separate cache entries per ZIP code" do
      other_current = build_current(name: "New York", country: "US")
      allow(mock_client).to receive(:current_weather)
        .with({ zip: "10001,us", units: "imperial" }).and_return(other_current)

      described_class.fetch("95014")
      result_ny = described_class.fetch("10001")

      expect(result_ny.from_cache).to be false
      expect(result_ny.data[:location]).to eq("New York, US")
    end
  end

  # ---------------------------------------------------------------------------
  # City name fallback (no ZIP in address)
  # ---------------------------------------------------------------------------
  describe "#fetch with no ZIP in the address" do
    let(:address) { "Cupertino, CA" }
    let(:current) { build_current(name: "Cupertino", country: "US") }

    before do
      allow(mock_client).to receive(:current_weather)
        .with({ city: address, units: "imperial" })
        .and_return(current)
    end

    it "returns a successful result" do
      expect(service.fetch.success?).to be true
    end

    it "returns nil for zip (no zip was provided in the address)" do
      expect(service.fetch.data[:zip]).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------------------
  describe "error handling" do
    let(:address) { "99999" }

    it "captures OpenWeather API faults" do
      fault = OpenWeather::Errors::Fault.new(
        { status: 404, headers: {}, body: { "message" => "city not found" } }
      )
      allow(mock_client).to receive(:current_weather).and_raise(fault)

      result = service.fetch
      expect(result.success?).to be false
      expect(result.error).to include("Weather API error")
      expect(result.error).to include("city not found")
    end

    it "captures unexpected errors" do
      allow(mock_client).to receive(:current_weather).and_raise(StandardError, "network timeout")

      result = service.fetch
      expect(result.success?).to be false
      expect(result.error).to include("unexpected error")
    end
  end
end
