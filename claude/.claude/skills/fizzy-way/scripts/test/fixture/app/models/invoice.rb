class Invoice < ApplicationRecord
  def total
    sum_lines
  end

  private
    def sum_lines
      line_items.sum
    end
end
