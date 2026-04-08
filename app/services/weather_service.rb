# frozen_string_literal: true

class WeatherService
  CACHE_DURATION = 30.minutes
  CACHE_KEY_PREFIX = "weather/forecast"

  Result = Struct.new(:data, :from_cache, :error, keyword_init: true) do
    def success? = error.nil?
  end

  def self.fetch(address)
    new(address).fetch
  end

  def initialize(address)
    @address = address.to_s.strip
    @client = OpenWeather::Client.new
  end

  def fetch
    zip = extract_zip(@address)

    if zip
      fetch_by_zip(zip)
    else
      fetch_by_city
    end
  rescue OpenWeather::Errors::Fault => e
    Result.new(error: "Weather API error: #{e.message}")
  rescue StandardError => e
    Result.new(error: "An unexpected error occurred: #{e.message}")
  end

  private

  def extract_zip(address)
    address.match(/\b(\d{5})(?:-\d{4})?\b/)&.captures&.first
  end

  def fetch_by_zip(zip)
    cache_key = "#{CACHE_KEY_PREFIX}/zip/#{zip}"
    from_cache = Rails.cache.exist?(cache_key)

    data = Rails.cache.fetch(cache_key, expires_in: CACHE_DURATION) do
      current = @client.current_weather(zip: "#{zip},us", units: "imperial")
      forecast = fetch_forecast(zip: "#{zip},us")
      build_weather_data(current, forecast, zip)
    end

    Result.new(data: data, from_cache: from_cache)
  end

  def fetch_by_city
    cache_key = "#{CACHE_KEY_PREFIX}/city/#{normalize(@address)}"
    from_cache = Rails.cache.exist?(cache_key)

    data = Rails.cache.fetch(cache_key, expires_in: CACHE_DURATION) do
      current = @client.current_weather(city: @address, units: "imperial")
      forecast = fetch_forecast(lat: current.coord.lat, lon: current.coord.lon)
      build_weather_data(current, forecast, nil)
    end

    Result.new(data: data, from_cache: from_cache)
  end

  # Calls the free-tier 5-day / 3-hour forecast endpoint via the client's
  # generic #get method and wraps the response in the gem's Hourly model so
  # the list items expose the same typed accessors as other forecast models.
  def fetch_forecast(params)
    raw = @client.get("2.5/forecast", params.merge(units: "imperial", cnt: 40))
    OpenWeather::Models::Forecast::Hourly.new(raw, { units: "imperial" })
  end

  def build_weather_data(current, forecast, zip)
    {
      zip: zip,
      location: "#{current.name}, #{current.sys.country}",
      current_temp: current.main.temp.round,
      feels_like: current.main.feels_like.round,
      temp_high: current.main.temp_max.round,
      temp_low: current.main.temp_min.round,
      humidity: current.main.humidity,
      description: current.weather.first.description.capitalize,
      icon: current.weather.first.icon,
      daily_forecasts: parse_daily_forecasts(forecast.list)
    }
  end

  def parse_daily_forecasts(list)
    list
      .group_by { |f| f.dt.to_date }
      .map do |date, periods|
        {
          date: date,
          temp_high: periods.map { |p| p.main.temp_max }.max.round,
          temp_low: periods.map { |p| p.main.temp_min }.min.round,
          description: periods.first.weather.first.description.capitalize,
          icon: periods.first.weather.first.icon
        }
      end
      .first(5)
  end

  def normalize(str)
    str.downcase.gsub(/[^a-z0-9]+/, "_")
  end
end
