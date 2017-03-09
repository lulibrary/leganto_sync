require 'csv'

require 'writeexcel'

require 'lusi_api/calendar'
require 'lusi_api/core/util'
require 'lusi_api/course'
require 'lusi_api/organisation'

require 'leganto_sync/version'


module LegantoSync

  # Defines common course/cohort attribute extractors for use in filters
  module Filters

    # Extractors for common course/cohort attributes

    COHORT_END_DATE = Proc.new { |course, cohort| cohort.end_date }
    COHORT_IDENTITY = Proc.new { |course, cohort| cohort.identity }
    COHORT_START_DATE = Proc.new { |course, cohort| cohort.start_date }

    COURSE_CATEGORY = Proc.new { |course, cohort| course.category_level }
    COURSE_DEPARTMENT = Proc.new { |course, cohort| course.major_department }
    COURSE_IDENTITY = Proc.new { |course, cohort| course.identity.course }
    COURSE_LONG_TITLE = Proc.new { |course, cohort| course.display_long_title }
    COURSE_MNEMONIC = Proc.new { |course, cohort| course.mnemonic }
    COURSE_SHORT_TITLE = Proc.new { |course, cohort| course.display_short_title }
    COURSE_TITLE = Proc.new { |course, cohort| course.title }
    COURSE_STATUS = Proc.new { |course, cohort| course.status }
    COURSE_YEAR = Proc.new { |course, cohort| course.identity.year }

  end


  # Implements a filter with a call() method which accepts a course and cohort and returns true if the course/cohort
  # should be included in the output, or false if not.
  class Filter

    # @!attribute [rw] extractor
    #   @return [Proc, Method] a proc or method which accepts a LUSI::API::Course::Module and a
    #     LUSI::API::Course::Cohort and returns a value to be matched against the values
    attr_accessor :extractor

    # @!attribute [rw] mode
    #   @return [Symbol] comparison mode - :include (match must be true) or :exclude (match must be false)
    attr_accessor :mode

    # @!attribute [rw] values
    #   @return [Object] the value or set of values to match against. This may be:
    #     Array, Hash or Set - the matched value must be a member of the collection
    #     Regexp - the matched value must match the regexp
    #     Other values are matched by equality
    attr_accessor :values

    # Initialises a new Filter instance
    # @param values [Object] the value of set of values to match against
    # @param mode [Symbol] :include (filter is true if value matches values) or :exclude (filter is true if value does
    #   not match values)
    # @param extractor [Proc, Method] extracts the value to match from a LUSI course/cohort. This may be passed as
    #   a code block instead of a parameter.
    # @return [void]
    def initialize(values = nil, mode = nil, extractor = nil, &block)
      self.extractor = extractor || block
      self.mode = mode || :include
      self.values = values
    end

    # Applies the filter to a LUSI course/cohort
    # @param course [LUSI::API::Course::Module] the LUSI course instance
    # @param cohort [LUSI::API::Course::Cohort] the LUSI cohort instance
    def call(course = nil, cohort = nil)
      value = self.extractor.call(course, cohort)
      if self.values.is_a?(Array) || self.values.is_a?(Hash) || self.values.is_a?(Set)
        # The filter values must include the course/cohort value
        result = self.values.include?(value)
      elsif self.values.is_a?(Regexp)
        # The course/cohort string value must match the filter values regexp
        result = self.values.match(value.to_s)
      else
        # The course/cohort value must be equal to the filter value
        result = self.values == value
      end
      # Negate the result if mode is :exclude (i.e. exclude anything which matches)
      self.mode == :include ? result : !result
    end

  end


  class Courses

    include LUSI::API::Core::Util

    # LUSI instructor roles
    INSTRUCTOR_ROLES = {
      'administrative staff' => true,
      'admissions_tutor' => true,
      'co-course convenor' => true,
      'co-director' => true,
      'course convenor' => true,
      'director of studies' => true,
      'director of teaching' => true,
      'head of department' => true,
      'library staff' => true,
      'part I director of studies' => true,
      'part II director of studies' => true,
      'partner administrative staff' => true,
      'partner course convenor' => true,
      'partner director of studies' => true,
      'subject librarian' => true,
      'teaching staff (not timetabled)' => true,
      'teaching staff (timetabled)' => true,
      'year 2 director of study' => true,
      'year 3 director of study' => true,
      'year 4 director of study' => true
    }

    # Alma processing department code
    PROCESSING_DEPARTMENT = 'Library'

    # Alma term codes
    TERMS = {
        lusi_lent: 'LENT',
        lusi_mich: 'MICHAELMAS',
        lusi_summ: 'SUMMER'
    }

    # @!attribute [rw] course_enrolments
    #   @return [LUSI::API::Enrolment::EnrolmentLookup] module enrolments from LUSI
    attr_accessor :course_enrolments

    # @!attribute [rw] courses
    #   @return [Array<LUSI::API::Course>] the list of course instances
    attr_accessor :courses

    # @!attribute [rw] current_academic_year
    #   @return [LUSI::API::Calendar::Year] the current academic year
    attr_accessor :current_academic_year

    # @!attribute [rw] departments
    #   @return [LegantoSync::Departments] the LegantoSync department loader
    attr_accessor :departments

    # @!attribute [rw] instructor_roles
    #   @return [Hash<String, LUSI::API::Person::StaffCourseRole>] the subset of the :staff_course_roles lookup table
    #     containing course instructor roles
    attr_accessor :instructor_roles

    # @!attribute [rw] lusi_api
    #   @return [LUSI::API::Core::API] the LUSI API instance used to retrieve data
    attr_accessor :lusi_api

    # @!attribute [rw] lusi_lookup
    #   @return [LUSI::API::Core::Lookup::LookupService] the LUSI lookup service used to retrieve data
    attr_accessor :lusi_lookup

    # @!attribute [rw] sort_key
    #   @return [Symbol] the sort order for departments - :identity, :mnemonic or :title
    attr_accessor :sort_key

    # Initializes a new Courses instance
    # @param lusi_api [LUSI::API::Core::API] the LUSI API instance used to retrieve data
    # @param lusi_lookup [LUSI::API::Core::Lookup::LookupService] the LUSI API lookup service
    # @param departments [LegantoSync::Departments] the department retrieval service
    # @param sort_key [Symbol] sort by
    # @param year [LUSI::API::Calendar::Year] the current academic year (defaults to the actual current academic year)
    # @return [void]
    def initialize(lusi_api = nil, lusi_lookup = nil, departments = nil, sort_key: nil, year: nil)
      self.current_academic_year = year || LUSI::API::Calendar::Year.get_current_academic_year(lusi_api, lusi_lookup)
      self.departments = departments
      self.lusi_api = lusi_api
      self.lusi_lookup = lusi_lookup
      self.sort_key = sort_key || :department
    end

    # Create a CSV row (array) for a specific cohort of a course
    # @param course [LUSI::API::Course::Module] the LUSI module
    # @param cohort [LUSI::API::Course::Cohort] the LUSI module's cohort
    # @param op [String] the course loader operation: DELETE, ROLLOVER, (any other = add/update)
    def alma_course_loader_row(course = nil, cohort = nil, op = '')

      # Initialise the row
      r = Array.new(31)

      # Return a header row if no course is specified
      if course.nil?
        r[0] = 'COURSE_CODE'
        r[1] = 'COURSE_TITLE'
        r[2] = 'SECTION_ID'
        r[3] = 'PROC_DEPT'
        r[4] = 'ACAD_DEPT'
        r[5] = 'TERM1'
        r[6] = 'TERM2'
        r[7] = 'TERM3'
        r[8] = 'TERM4'
        r[9] = 'START_DATE'
        r[10] = 'END_DATE'
        r[11] = 'NUM_OF_PARTICIPANTS'
        r[12] = 'WEEKLY_HOURS'
        r[13] = 'YEAR'
        r[14] = 'SEARCH_ID1'
        r[15] = 'SEARCH_ID2'
        r[16] = 'SEARCH_ID3'
        r[17] = 'INSTR1'
        r[18] = 'INSTR2'
        r[19] = 'INSTR3'
        r[20] = 'INSTR4'
        r[21] = 'INSTR5'
        r[22] = 'INSTR6'
        r[23] = 'INSTR7'
        r[24] = 'INSTR8'
        r[25] = 'INSTR9'
        r[26] = 'INSTR10'
        r[27] = 'ALL_INSTRUCTORS'
        r[28] = 'OPERATION'
        r[29] = 'OLD_COURSE_CODE'
        r[30] = 'OLD_COURSE_SECTION'
        return r
      end

      # The course section ID isn't relevant for now, so set it to a default value for all courses
      section_id = '1'

      # The department code of the major (administering) department for the course.
      # Department codes are the talis_code attibute of LUSI::API::Organisation::Unit
      org_unit_identities = org_units(course).map { |u| u.talis_code }
      academic_department = org_unit_identities[2]
      institution = org_unit_identities[0]
      faculty = org_unit_identities[1]

      # The course code must match the Moodle course ID: lusi-courseId-yearId-cohortId
      course_code = "lusi-#{course.identity.course}-#{course.identity.year}-#{cohort.identity}"

      # Get the instructors from the course enrolments
      enrolments = self.course_enrolments.fetch(course)
      if enrolments
        instructor_enrolments = enrolments.select { |e| self.instructor_roles.has_key?(e.enrolment_role.identity) }
        instructors = instructor_enrolments.map { |e| e.username }
        instructors.uniq!
        instructors = instructors.join(',')
        instructors = nil if instructors.nil? || instructors.empty?
      else
        instructors = nil
      end

      # The old course code and section are required for rollover
      if op == 'ROLLOVER'
        # TODO: work out how we handle rollover
        old_course_code = nil
        old_course_section = nil
      else
        # Ignored for non-rollover operations
        old_course_code = nil
        old_course_section = nil
      end

      # Course code
      r[0] = field(course_code, 50)
      # Course title
      r[1] = field(cohort.display_long_title, 255)
      # Section ID
      r[2] = field(section_id, 50)
      # Academic departments
      r[3] = academic_department
      # Processing department
      r[4] = PROCESSING_DEPARTMENT
      # Term 1
      r[5] = nil
      # Term 2
      r[6] = nil
      # Term 3
      r[7] = nil
      # Term 4
      r[8] = nil
      # Start date
      r[9] = cohort.start_date ? cohort.start_date.strftime('%Y-%m-%d') : nil
      # End date
      r[10] = cohort.end_date ? cohort.end_date.strftime('%Y-%m-%d') : nil
      # Number of participants
      r[11] = course.enrolled_students.to_i
      # Weekly hours
      r[12] = nil
      # Year
      r[13] = self.lusi_year(course.identity.year)
      # Searchable ID 1
      r[14] = field(course.mnemonic, 50)
      # Searchable ID 2
      r[15] = field(faculty, 50)
      # Searchable ID 3
      r[16] = field(institution, 50)
      # Instructor 1
      r[17] = nil
      # Instructor 2
      r[18] = nil
      # Instructor 3
      r[19] = nil
      # Instructor 4
      r[20] = nil
      # Instructor 5
      r[21] = nil
      # Instructor 6
      r[22] = nil
      # Instructor 7
      r[23] = nil
      # Instructor 8
      r[24] = nil
      # Instructor 9
      r[25] = nil
      # Instructor 10
      r[26] = nil
      # All instructors
      r[27] = instructors
      # Operation
      r[28] = field(op, 50)
      # Old course code
      r[29] = field(old_course_code, 50)
      # Old course section
      r[30] = field(old_course_section, 50)

      # Return the row
      r

    end

    # Returns a lookup table of LUSI course enrolments
    # @param year [LUSI::API::Calendar::Year] retrieve course enrolments for this academic year (default: current year)
    # @param year_identity [String] retrieve course enrolments for this academic year identity code
    # @return [LUSI::API::Enrolment::EnrolmentLookup] the enrolment lookup table
    def course_enrolments(year: nil, year_identity: nil)

      # TODO: make sure course_enrolments deals with multiple years!

      # Return the enrolments if available
      return @course_enrolments unless @course_enrolments.nil?

      year_identity ||= self.lusi_year_identity(year || self.current_academic_year)

      # Get the year for course enrolment retrieval
      year ||= self.current_academic_year

      # Get the enrolments from LUSI
      enrolments = LUSI::API::Course::StaffModuleEnrolment.get_instance(self.lusi_api, self.lusi_lookup,
                                                                        year_identity: year_identity)

      # Construct and return the lookup table for the enrolments
      @course_enrolments = LUSI::API::Enrolment::EnrolmentLookup.new(enrolments)

    end

    # Returns a sorted array of LUSI courses
    # @param sort_key [Symbol] sort by
    # @param year [LUSI::API::Calendar::Year] retrieve courses for this academic year (default: current year)
    def courses(*years, sort_key: nil)

      # Return the courses if available
      return @courses unless @courses.nil?

      # Get the year for course retrieval
      if years.nil? || years.empty?
        #year_identities = [LUSI::API::Core::Util.lusi_year_identity(self.current_academic_year)]
        year_identities = [self.lusi_year_identity(self.current_academic_year)]
      else
        year_identities = years.map { |year| self.lusi_year_identity(year) }
      end

      # Select the comparison for sorting
      sort_key ||= self.sort_key
      case sort_key
        when :department
          compare = Proc.new { |c1, c2| department_sort_key(c1) <=> department_sort_key(c2) }
        when :mnemonic
          compare = Proc.new { |c1, c2| c1.mnemonic.to_s.upcase <=> c2.mnemonic.to_s.upcase }
        when :title
          compare = Proc.new { |c1, c2| c1.title.to_s.upcase <=> c2.title.to_s.upcase }
        when :title_long
          compare = Proc.new { |c1, c2| c1.display_long_title.to_s.upcase <=> c2.display_long_title.to_s.upcase }
        when :title_short
          compare = Proc.new { |c1, c2| c1.display_short_title.to_s.upcase <=> c2.display_short_title.to_s.upcase }
        else
          compare = Proc.new { |c1, c2| identity_sort_key(c1) <=> identity_sort_key(c2) }
      end

      # Get the courses from LUSI
      @courses = []
      year_identities.each do |year_identity|
        # Add the courses for this year to the list
        LUSI::API::Course::Module.get_instance(self.lusi_api, self.lusi_lookup, live_only: false,
                                               year_identity: year_identity).each { |course| @courses.push(course) }
        # Get the current course enrolments from LUSI
        # TODO: make sure course_enrolments deals with multiple years!
        self.course_enrolments(year_identity: year_identity)
      end

      # Sort and return the courses
      @courses.sort!(&compare)

    end

    # Iterates over courses, applying filters to reject unwanted courses
    # Positional parameters are the filters to be applied
    # @yield [course, cohort] Passes the course and cohort to the block
    # @yieldparam course [LUSI::API::Course::Module] the course module
    # @yieldparam cohort [LUSI::API::Course::Cohort] the course module cohort
    def each(*filters, &block)
      if filters.nil? || filters.empty?
        # Avoid calling self.filter() if there are no filters defined
        self.courses.each do |course|
          course.cohorts.each { |cohort| block.call(course, cohort) }
        end
      else
        # Use the defined filters
        self.courses.each do |course|
          course.cohorts.each { |cohort| block.call(course, cohort) if filter(course, cohort, filters) }
        end
      end
    end

    # Applies the active filters to the course/cohort to determine whether it should be included in the output
    # @param course [LUSI::API::Course::Module] the course
    # @param cohort [LUSI::API::Course::Cohort] the course cohort
    # @return [Boolean] true if the course/cohort should be included, false otherwise
    def filter(course, cohort, filters)
      # Return false if any of the filters returns false
      filters.each { |f| return false unless f.call(course, cohort) }
      # If we get here, all filters returned true
      true
    end

    # Returns a subset of the :staff_course_roles lookup table containing course instructor roles
    # @return [Hash<String, LUSI::API::Person::StaffCourseRole>] the course instructor roles
    def instructor_roles
      return @instructor_roles unless @instructor_roles.nil?
      staff_course_roles = self.lusi_lookup.service(:staff_course_role)
      if staff_course_roles
        @instructor_roles = staff_course_roles.select { |k,v| INSTRUCTOR_ROLES.include?(v.description.downcase) }
      else
        @instructor_roles = []
      end
      @instructor_roles
    end

    # Creates a list of courses in a CSV file suitable for import into Alma from the course loader
    # @param filename [String] the filename of the course loader file
    def to_alma_course_loader(filename = nil, op = nil, filters: nil)

      # Check the operation, default to regular import if invalid
      op = op.to_s.upcase
      op = '' unless ['', 'DELETE', 'ROLLOVER'].include?(op)

      # Build a mapping of department identities to LUSI organisation units
      #@department_map = {}
      #self.departments.departments.each { |d| @department_map[d.identity] = d }

      # Write the course data to a tab-separated CSV file
      CSV.open(filename, 'wb', col_sep: "\t") do |csv|
        # Write the header line
        csv << alma_course_loader_row
        # For each course, add a row for each cohort using the cohort as the section ID
        self.each(*filters) { |course, cohort| csv << alma_course_loader_row(course, cohort, op) }
      end

    end

    # Returns a list of LUSI year instances
    # @param year [LUSI::API::Calendar::Year] the base year (defaults to the current academic year)
    # @param years_previous [Integer] the number of years previous to the base year
    # @param years_next [Integer] the number of years following the base year
    def years(year = nil, years_previous: nil, years_next: nil)
      result = []
      result.push(*(year.previous(years_previous))) if years_previous && years_previous > 0
      result.push(*(year.next(years_next))) if years_next && years_next > 0
      result
    end

    protected

    # Returns the major department for the course
    # @param course [LUSI::API::Course::Module] the LUSI course module
    # @return [LUSI::API::Course::CourseDepartment] the major department for the course
    def course_department(course = nil)
      course && course.course_departments ? (course.course_departments.select { |u| u.is_major_department })[0] : nil
    end

    # Returns the organisation unit for a course department
    # @param course [LUSI::API::Course::Module] the LUSI course module
    # @return [LUSI::API::Organisation::Unit] the organisation unit instance of the major department for the course
    def department(course = nil)
      dept = course_department(course)
      dept ? dept.org_unit : nil
    end

    # Returns the course institution/faculty/department as a single string for sorting
    # @param course [LUSI::API::Course::Module] the LUSI course module
    # @return [String] the department's sort key
    def department_sort_key(course)
      # Get the major department's organisation unit instance for the course
      dept = department(course)
      return '' unless dept
      # Get the parent organisation unit titles
      titles = org_units(course).map { |u| u ? u.title.upcase : '' }
      # Return a sort key which will group by institution, then faculty, then department
      titles.join('*')
    end

    # Returns a string row field trimmed to the specified length
    # @param value [String] the field value
    # @param length [Integer] the maximum field length
    # @param empty [Object, nil] the value to return if the field value is nil or empty
    # @return [String] the formatted field value
    def field(value, length = nil, empty = nil)
      value = empty if value.nil? || value.empty?
      length && value ? value[0...length] : value
    end

    # Returns the course identity as a single string for sorting
    # @param course [LUSI::API::Course::Module] the LUSI course module
    # @return [String] the identity's sort key
    def identity_sort_key(course)
      return '' unless course
      # Courses with the same identity code should sort in most-recent date order
      # Assuming that year identities are numerically ascending, the following will produce the desired descending order
      year_descending = 999999 - course.identity.year.to_i
      # Return a sort key which will group by course, then year (most-recent first)
      '%s*%06d' % [course.identity.course, year_descending]
    end

    # Returns the ancestor organisation unit instances of the major department for the course
    # @param course [LUSI::API::Course::Module] the LUSI course module
    # @return [Array<LUSI::API::Organisation::Unit>] the ancestor organisation units in furthest-to-nearest order
    #   [institution, faculty, dept]
    def org_units(course = nil)
      dept = department(course)
      result = []
      until dept.nil?
        result.unshift(dept)
        dept = dept.parent
      end
      result
    end

  end

end
