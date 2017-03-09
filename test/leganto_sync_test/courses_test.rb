require 'lusi_api/core/lookup'

require 'leganto_sync/courses'

require_relative '../test_helper'


class CoursesTest < Test

  @@mutex_courses = Mutex.new
  @@courses = nil

  def setup
    super
  end

  def test_to_course_loader
    courses = get_courses
    courses.to_alma_course_loader('/home/lbaajh/tmp/legantosync/courses/courses.xls')
  end

  def test_to_course_loader_filters
    courses = get_courses
    ignore_mnemonics = ['CHEM501', 'EUROESB403', 'OWT605', 'PHYS356', 'PMIP506', 'PSYC304']
    ignore_titles = [
      '(capstone|china|client|consultancy|development|design|diploma|final|group|independent|individual.*|laboratory|linking|mphys|research|studio|translation|uk|year) project(?!s)',
      'dissertation',
      '(extended|ma) essay',
      'faculty assessment',
      'independent( social work)? research',
      'independent|individual study',
      'independent work based learning',
      'industrial attache?ment',
      'internship',
      '\-lab',
      '\(lab\)',
      'laboratory',
      'placement',
      'project-i',
      'project challenge',
      'registry test',
      'research proposal',
      'self[\s\-]directed study',
      'schools volunteering',
      'sharepoint',
      'test module'
    ].join('|')
    filters = [
        LegantoSync::Filter.new(ignore_mnemonics, :exclude, LegantoSync::Filters::COURSE_MNEMONIC),
        LegantoSync::Filter.new(/SWTEST|THESIS/i, :exclude, LegantoSync::Filters::COURSE_MNEMONIC),
        LegantoSync::Filter.new(Regexp.compile(ignore_titles, true), :exclude, LegantoSync::Filters::COURSE_TITLE)
    ]
    courses.to_alma_course_loader('/home/lbaajh/tmp/legantosync/courses/courses-filtered.xls', filters: filters)
  end

  def test_to_course_loader_delete
    courses = get_courses
    courses.to_alma_course_loader('/home/lbaajh/tmp/legantosync/courses/courses-delete.xls', :delete)
  end

  def test_to_course_loader_rollover
    courses = get_courses
    courses.to_alma_course_loader('/home/lbaajh/tmp/legantosync/courses/courses-rollover.xls', :rollover)
  end

  protected

  def get_courses
    lusi_api = get_lusi_api
    lusi_lookup = get_lusi_lookup
    @@mutex_courses.synchronize do
      return @@courses if @@courses
      @@courses = LegantoSync::Courses.new(lusi_api, lusi_lookup)
      # Populate with last and this years' courses
      years = @@courses.current_academic_year.range(-1, 0)
      @@courses.courses(*years)
      # Return the Courses instance
      @@courses
    end
  end

end