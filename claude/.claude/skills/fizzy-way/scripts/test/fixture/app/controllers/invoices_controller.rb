class InvoicesController < ApplicationController
  def update
    @invoice.update(invoice_params)
    redirect_to @invoice
  end

  def close
    @invoice.close
  end
end
