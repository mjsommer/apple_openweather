# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Forecasts", type: :request do
  let(:mock_result_data) do
    {
      zip: "95014",
      location: "Cupertino, US",
      current_temp: 72,
      feels_like: 70,
      temp_high: 78,
      temp_low: 60,
      humidity: 45,
      description: "Clear sky",
      icon: "01d",
      daily_forecasts: [
        { date: Date.today, temp_high: 78, temp_low: 60, description: "Clear sky", icon: "01d" },
        { date: Date.tomorrow, temp_high: 74, temp_low: 58, description: "Partly cloudy", icon: "02d" }
      ]
    }
  end

  describe "GET /" do
    context "with no address params" do
      it "renders the search form with 200" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Weather Forecast")
        expect(response.body).to include("address-input")
      end

      it "does not show any forecast data" do
        get root_path
        expect(response.body).not_to include("current-weather")
      end
    end

    context "with a valid address" do
      before do
        success_result = WeatherService::Result.new(
          data: mock_result_data,
          from_cache: false,
          error: nil
        )
        allow(WeatherService).to receive(:fetch).with("95014").and_return(success_result)
      end

      it "returns 200" do
        get root_path, params: { address: "95014" }
        expect(response).to have_http_status(:ok)
      end

      it "displays the location name" do
        get root_path, params: { address: "95014" }
        expect(response.body).to include("Cupertino, US")
      end

      it "displays the current temperature" do
        get root_path, params: { address: "95014" }
        expect(response.body).to include("72")
      end

      it "displays humidity" do
        get root_path, params: { address: "95014" }
        expect(response.body).to include("45%")
      end

      it "displays the ZIP code tag" do
        get root_path, params: { address: "95014" }
        expect(response.body).to include("ZIP 95014")
      end

      it "does not show a cache badge" do
        get root_path, params: { address: "95014" }
        expect(response.body).not_to include("cache-badge")
      end
    end

    context "when the result is from cache" do
      before do
        cached_result = WeatherService::Result.new(
          data: mock_result_data,
          from_cache: true,
          error: nil
        )
        allow(WeatherService).to receive(:fetch).and_return(cached_result)
      end

      it "shows the cache indicator badge" do
        get root_path, params: { address: "95014" }
        expect(response.body).to include("cache-badge")
        expect(response.body).to include("Served from cache")
      end

      it "includes the ZIP in the cache badge" do
        get root_path, params: { address: "95014" }
        expect(response.body).to include("ZIP: 95014")
      end
    end

    context "when the service returns an error" do
      before do
        error_result = WeatherService::Result.new(data: nil, from_cache: false, error: "City not found")
        allow(WeatherService).to receive(:fetch).and_return(error_result)
      end

      it "returns 200" do
        get root_path, params: { address: "00000" }
        expect(response).to have_http_status(:ok)
      end

      it "displays the error message" do
        get root_path, params: { address: "00000" }
        expect(response.body).to include("City not found")
        expect(response.body).to include("alert-error")
      end

      it "does not render forecast content" do
        get root_path, params: { address: "00000" }
        expect(response.body).not_to include("current-weather")
      end
    end
  end
end
