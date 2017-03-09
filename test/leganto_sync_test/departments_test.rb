require 'leganto_sync/departments'

require_relative '../test_helper'


class DepartmentsTest < Test

  def setup
    super
    @departments = LegantoSync::Departments.new(self.get_lusi_api)
  end

  def test_to_excel
    @departments.to_excel('/home/lbaajh/tmp/legantosync/depts/depts.xls', code: :talis_code)
  end

end