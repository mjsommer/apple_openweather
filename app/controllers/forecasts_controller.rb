# frozen_string_literal: true

class ForecastsController < ApplicationController
  def index
    return unless params[:address].present?

    result = WeatherService.fetch(params[:address])

    if result.success?
      @forecast = result.data
      @from_cache = result.from_cache
    else
      @error = result.error
    end
  end
end
