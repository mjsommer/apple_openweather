Rails.application.routes.draw do
  root "forecasts#index"

  get "up" => "rails/health#show", as: :rails_health_check
end
