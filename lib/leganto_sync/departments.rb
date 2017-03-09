require 'writeexcel'

require 'lusi_api/organisation'

require "leganto_sync/version"


module LegantoSync

  class Departments

    # @!attribute [rw] lusi_api
    #   @return [LUSI::API::Core::API] the LUSI API instance used to retrieve data
    attr_accessor :lusi_api

    # @!attribute [rw] departments
    #   @return [Array<LUSI::API::Organisation::Unit>]
    attr_accessor :departments

    # @!attribute [rw] organisation
    #   @return [LUSI::API::Organisation::Organisation] the LUSI organisation instance
    attr_accessor :organisation

    # @!attribute [rw] sort_key
    #   @return [Symbol] the sort order for departments - :identity, :mnemonic or :title
    attr_accessor :sort_key

    # Initializes a new Departments instance
    # @param lusi_api [LUSI::API::Core::API] the LUSI API instance used to retrieve data
    # @param sort_key [Symbol] the default sort key for department ordering (:identity, :mnemonic, :talis_code, :title)
    # @return [void]
    def initialize(lusi_api = nil, sort_key: nil)
      self.lusi_api = lusi_api
      self.sort_key = sort_key || :title
    end

    # Returns a sorted array of LUSI departments
    # @param sort_key [Symbol] sort by :mnemonic, :identity or (by default) title
    def departments(sort_key: nil)

      # Return the departments if available
      return @departments unless @departments.nil?

      # Select the comparison for sorting
      sort_key ||= self.sort_key
      case sort_key
        when :mnemonic
          compare = Proc.new { |unit1, unit2| "#{unit1.mnemonic.to_s}#{unit1.identity}".upcase <=> "#{unit2.mnemonic.to_s}#{unit2.identity}".upcase }
        when :identity
          compare = Proc.new { |unit1, unit2| unit1.identity.to_s.upcase <=> unit2.identity.to_s.upcase }
        when :talis_code
          compare = Proc.new { |unit1, unit2| unit1.talis_code.to_s.upcase <=> unit2.talis_code.to_s.upcase }
        else
          compare = Proc.new { |unit1, unit2| "#{unit1.title.to_s}#{unit1.identity}".upcase <=> "#{unit2.title.to_s}#{unit2.identity}".upcase }
      end

      # Get the departments from LUSI
      @departments = []
      self.organisation.each(:department) { |unit| @departments.push(unit) }

      # Sort and return the departments
      @departments.sort!(&compare)

    end

    # Returns the LUSI organisation instance
    # @return [LUSI::API::Organisation] the LUSI organisation instance
    def organisation
      if @organisation.nil?
        @organisation = LUSI::API::Organisation::Organisation.new
        @organisation.load(self.lusi_api, in_use_only: false)
      end
      @organisation
    end

    # Creates a list of department codes and names in a Microsoft Excel (97-2003) spreadsheet suitable for import
    # into Alma from Fulfillment Configuration -> Courses -> Academic Departments -> Import
    # @param filename [String] the filename of the spreadsheet to be created
    # @param code [Symbol] the attribute to use as the department code (:identity, :mnemonic, :talis_code)
    # @param institution [String, LUSI::API::Organisation::Unit] the institution identity or instance for which
    #   departments are required
    # @return [void]
    def to_excel(filename = nil, code: nil, institution: nil)

      # Get the institution identity
      case
        when institution.nil?
          institution_id = nil
        when institution.is_a?(LUSI::API::Organisation::Unit) && institution.type == :institution
          institution_id = institution.identity
        else
          institution_id = institution.to_s
      end

      # Select the code attribute for the department
      case code
        when :mnemonic
          unit_code = Proc.new { |unit| unit.mnemonic }
        when :talis_code
          unit_code = Proc.new { |unit| unit.talis_code }
        else
          unit_code = Proc.new { |unit| unit.identity }
      end

      # Create an Excel 97-2003-compatible spreadsheet
      workbook = WriteExcel.new(filename)

      # Alma requires a worksheet named 'CodeTable'
      worksheet = workbook.add_worksheet('CodeTable')

      # Alma requires the first row to be column headings 'Code' and 'Description'
      worksheet.write(0, 0, 'Code')
      worksheet.write(0, 1, 'Description')

      # Add each department as a row containing code and description columns
      row = 1
      self.departments.each do |unit|
        if include_department(unit, institution_id)
          worksheet.write(row, 0, unit_code.call(unit) )
          worksheet.write(row, 1, unit.title)
          row += 1
        end
      end

      # Close the spreadsheet
      workbook.close

      # Return the workbook instance
      workbook

    end

    protected

    def include_department(department = nil, institution_id = nil)
      return true if institution_id.nil?
      faculty = department.nil? ? nil : department.parent
      institution = faculty.nil? ? nil : faculty.parent
      return institution.nil? ? false : institution.identity == institution_id
    end

  end

end
