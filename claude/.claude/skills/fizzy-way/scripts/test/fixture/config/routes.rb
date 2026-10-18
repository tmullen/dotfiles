Rails.application.routes.draw do
  resources :invoices, only: %i[ index show edit update ] do
    member do
      post :close
    end
  end
  post :archive, to: "archives#archive"

  resources :estimates do
    post :close
  end
end
