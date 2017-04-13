require 'leganto_sync/reading_lists/aspire'

require 'lusi_api/core/api'
require 'lusi_api/core/lookup'

require 'leganto_sync/courses'

require_relative '../test_helper'


class AspireReadingListsTest < Test

  @@aspire_api = nil
  @@aspire_client_id = ENV['ASPIRE_API_CLIENT_ID']
  @@aspire_secret = ENV['ASPIRE_API_SECRET']
  @@aspire_tenant = ENV['ASPIRE_TENANT']
  @@aspire_tenancy_root = ENV['ASPIRE_TENANCY_ROOT']

  @@email = nil
  @@email_conf = ENV['EMAIL_CONF']
  @@email_map = ENV['EMAIL_MAP']

  @@ldap = nil
  @@ldap_base = ENV['LDAP_BASE']
  @@ldap_host = ENV['LDAP_HOST']
  @@ldap_password = ENV['LDAP_PASSWORD']
  @@ldap_user = ENV['LDAP_USER']

  @@mutex_aspire_api = Mutex.new
  @@mutex_email = Mutex.new
  @@mutex_ldap = Mutex.new
  @@mutex_users = Mutex.new

  @@users = nil
  @@users_file = ENV['ASPIRE_USERS']


  def setup

    super

    @dir_aspire = ENV['DIR_ASPIRE']

    @course_file = ENV['COURSE_FILE']

    @email_domains = ENV['EMAIL_DOMAINS'].split(';')

    @ldap_email = ENV['LDAP_EMAIL']
    @ldap_email_alt = ENV['LDAP_EMAIL_ALT']
    @ldap_uid = ENV['LDAP_UID']

    @list_id_1 = ENV['ASPIRE_LIST_ID_1']
    @list_id_2 = ENV['ASPIRE_LIST_ID_2']
    @list_id_3 = ENV['ASPIRE_LIST_ID_3']
    @list_uri_1 = "#{@@aspire_tenancy_root}/lists/#{@list_id_1}"
    @list_uri_2 = "#{@@aspire_tenancy_root}/lists/#{@list_id_2}"
    @list_uri_3 = "#{@@aspire_tenancy_root}/lists/#{@list_id_3}"

    @list_file = ENV['ASPIRE_LIST_FILE']

    @factory = LegantoSync::ReadingLists::Aspire::Factory.new(self.get_aspire_api, email_selector: self.get_email,
                                                              ldap_lookup: self.get_ldap, users: self.get_users)

  end

  # def test_email_selector
  #
  #   email = self.get_email
  #
  #   emails_1 = %w(bob.sheep@farm.org b.sheep@lancaster.ac.uk bsheep@lancs.ac.uk b.sheep@lancaster.edu.gh
  #                 bob.sheep@gmail.com)
  #   emails_2 = %w(bob.sheep@farm.org b.sheep@lancaster.ac.uk bsheep@lancs.ac.uk bob.sheep@gmail.com)
  #   emails_3 = %w(bob.sheep@farm.org b.sheep@lancaster.edu.gh bsheep@lancs.ac.uk bob.sheep@gmail.com)
  #   emails_4 = %w(bob.sheep@farm.org bsheep@uclan.ac.uk bsheep@lancs.ac.uk bob.sheep@gmail.com)
  #   emails_5 = %w(bob.sheep@farm.org bsheep@uclan.ac.uk b.sheep@lancaster.edu.gh bob.sheep@gmail.com)
  #   emails_6 = %w(bob.sheep@farm.org bsheep@lancs.ac.uk bob.sheep@gmail.com)
  #   emails_7 = %w(bob.sheep@farm.org bob.sheep@gmail.com)
  #
  #   assert_equal 'b.sheep@lancaster.ac.uk', email.email(emails_1)
  #   assert_equal 'b.sheep@lancaster.ac.uk', email.email(emails_2)
  #   assert_equal 'b.sheep@lancaster.edu.gh', email.email(emails_3)
  #   assert_equal 'bsheep@lancaster.ac.uk', email.email(emails_4)
  #   assert_equal 'b.sheep@lancaster.edu.gh', email.email(emails_5)
  #   assert_equal 'bsheep@lancaster.ac.uk', email.email(emails_6)
  #   assert_equal 'bob.sheep@farm.org', email.email(emails_7)
  #
  # end
  #
  # def test_ldap_lookup
  #   ldap = self.get_ldap
  #   assert_nil ldap.find('notthere@does.not.exist')
  #   assert_equal @ldap_uid, ldap.find(@ldap_email)
  #   assert_equal @ldap_uid, ldap.find(@ldap_email_alt)
  # end
  #
  # def test_user_lookup
  #   users = self.get_users
  #   users.each do |uri, user|
  #     email = user.primary_email
  #     email_user, email_domain = email.split('@')
  #     unless @email_domains.include?("@#{email_domain}")
  #       # If the primary email domain is not one of the expected domains, there must not be an email with one of the
  #       # expected domains
  #       user.email.each do |e|
  #         e_user, e_domain = e.split('@')
  #         refute_includes @email_domains, e_domain
  #       end
  #     end
  #   end
  # end

  def test_reading_list

    citation_secondary_types = {
      'article' => 'CR',
      'audio document' => 'VD',
      'audio-visual document' => 'VD',
      'book' => 'BK',
      'chapter' => 'BK_C',
      'document' => 'DO',
      'image' => 'OTHER',
      'journal' => 'JR',
      'legal case document' => 'CASE',
      'legal document' => 'LEGAL_DOCUMENT',
      'legislation' => 'LEGISLATION',
      'proceedings' => 'OTHER',
      'thesis' => 'OTHER',
      'unknown type' => 'OTHER',
      'web page' => 'WS',
      'web site' => 'WS'
    }

    list_ids = [
        '646045B7-C59F-7332-B8DC-FAD38832BFD2',   # MBChB1: Recommended resources for Year 1 2016-17
        'A56880F3-10B3-45EC-FD16-D29D0198AEE3',   # LAW.103x: Law of Contracts 2016-17
        '6B97ECF0-40F5-8579-D0C2-8E587B64DDAF',   # HIST318: Vikings and sea-kings 2016-17
        'FA868747-71ED-F5C5-6061-23F5C999C9CF',   # LEC114: Society and Space 2016-17
        '30DC30E6-2943-C16D-C8FF-4B227F00A603',   # MKTG101: Marketing 2016-17
        '5657C91E-71E3-AA07-290E-4524D5CB8C00',   # GHANA GH-MKTG101: Marketing 2016-17
        '0DAA7701-1FB8-128C-6BB3-181CDD286EC0',   # GHANA GH-MKTG101: Marketing 2015-16
        '96D71905-CDBC-61F8-816E-E05FF8DBA518'    # MBChB1: Recommended resources for Year 1 2015-16
    ]

    courses = get_courses

    csv = nil
    csv_file = nil
    file_count = 0
    file_items = 0
    file_max = 0
    new_file = true

    CSV.open("#{ENV['DIR_ALMA']}/lists/reading_lists_0.csv", 'wb', {force_quotes: true}) do |csv|
      csv << alma_reading_list_loader_row
      list_ids.each do |list_id|
        # Get the list from the Aspire API
        list_uri = "#{@@aspire_tenancy_root}/lists/#{list_id}"
        list = @factory.get(list_uri)
        write_reading_list(csv, list, courses)
      end
      # Get the number of items in the list
      # list_items = list.length
      #
      # # Repeat while a new file is required to contain the list
      # while true
      #
      #   # Create a new file if required by a previous iteration
      #   if new_file
      #
      #     # Close any current file
      #     csv_file.close if csv_file
      #
      #     # Get the new filename and increment the file counter
      #     file_name = "#{ENV['DIR_ALMA']}/reading_lists_#{file_count}.csv"
      #     file_count += 1
      #
      #     # Open the new file and create a CSV wrapper for it
      #     csv_file = open(file_name, 'wb')
      #     csv = CSV.new(csv_file, {force_quotes: true})
      #
      #     # Write the column headings
      #     csv << alma_reading_list_loader_row
      #
      #     # Reset the count of items in the file and clear the new_file flag
      #     file_items = 1    # Include the header row
      #     new_file = false
      #
      #   end
      #
      #   # Check that the list would not exceed the maximum file size
      #   if file_max > 0 and file_items + list_items > file_max
      #     # The list would exceed the maximum file size, create a new file and write the whole list to it
      #     new_file = true
      #     continue
      #   end
      #
      #   # Write the list
      #   file_items += list_items
      #   write_reading_list(csv, list_id, courses)
      #
      #   # Exit the waiting-for-new-file loop
      #   break
      #
      # end

    end

    csv_file.close if csv_file

  end

  def notest_reading_list_section(section)
    name = (section.name || '').downcase
    case name
      when 'additional readings'
      when 'background', 'background reading'
      when 'core', 'core reading'
      when 'course texts'
      when 'essential', 'essential reading', 'essential texts'
      when 'further reading'
      when 'journals'
        # ???
      when 'key texts'
      when 'lent', 'lent term'
      when 'michaelmas', 'michaelmas term'
      when 'summer', 'summer term'
      when 'optional', 'optional reading'
      when 'other reading', 'other [useful] texts'
      when 'our recommendations'
      when 'primary reading', 'primary text'
      when 'recommended', 'recommended reading', 'recommended .* texts'
      when 'secondary reading', 'secondary texts', 'secondary literature'
      when 'set films', 'set texts'
      when 'students expected to purchase', 'get your own copies'
      when 'suggested', 'suggested reading'
      when 'supplementary', 'supplementary reading'
      when 'term [n]'
      when 'online resources', 'websites', 'resources - websites', 'useful websites'
        # ???
      when 'week [n]|one|two...', 'weeks [n] and|& [m]', 'weeks [n]-[m]'
        # ???
    end
  end

  protected

  def alma_reading_list_loader_row(list = nil, item = nil, course_code = nil)

    row = []

    if list.nil?
      row[0] = 'course_code'
      row[1] = 'Section id'
      row[2] = 'Searchable id1'
      row[3] = 'Searchable id2'
      row[4] = 'Searchable id3'
      row[5] = 'Reading_list_code'
      row[6] = 'Reading list name'
      row[7] = 'Reading List Description'
      row[8] = 'Reading lists Status'
      row[9] = 'RLStatus'
      row[10] = 'visibility'
      row[11] = 'owner_user_name'
      row[12] = 'section_name'
      row[13] = 'section_description'
      row[14] = 'section_start_date'
      row[15] = 'section_end_date'
      row[16] = 'citation_secondary_type'
      row[17] = 'citation_status'
      row[18] = 'citation_tags'
      row[19] = 'citation_originating_system_id'
      row[20] = 'citation_title'
      row[21] = 'citation_journal_title'
      row[22] = 'citation_author'
      row[23] = 'citation_publication_date'
      row[24] = 'citation_edition'
      row[25] = 'citation_isbn'
      row[26] = 'citation_issn'
      row[27] = 'citation_place_of_publication'
      row[28] = 'citation_publisher'
      row[29] = 'citation_volume'
      row[30] = 'citation_issue'
      row[31] = 'citation_pages'
      row[32] = 'citation_start_page'
      row[33] = 'citation_end_page'
      row[34] = 'citation_doi'
      row[35] = 'citation_chapter'
      row[36] = 'citation_source'
      row[37] = 'citation_note'
      row[38] = 'additional_person_name'
      row[39] = 'citation_public_note'
      row[40] = 'external_system_id'
      return row
    end

    list_owner = list.owner[0] || list.creator[0]
    list_status = 'BeingPrepared'
    list_visibility = 'RESTRICTED'
    rl_status = 'DRAFT'

    # Concatenate nested sections into a single section name
    # item.parent_sections returns sections in nearest-furthest order, but we want to concatenate in furthest-nearest
    # order, so we reverse the section list
    sections = item.parent_sections
    section_description = ''
    section_end_date = ''
    section_name = sections.reverse.join(' - ')
    section_start_date = ''
    # Take the section description from the nearest enclosing section with a description
    sections.each do |section|
      if section.description
        section_description = section.description
        break
      end
    end

    citation_status = 'BeingPrepared'

    resource = item.resource

    row = []
    # course_code
    row[0] = course_code[0]
    # Section id
    row[1] = course_code[1]
    # Searchable id1
    row[2] = course_code[2]
    # Searchable id2
    row[3] = course_code[3]
    # Searchable id3
    row[4] = course_code[4]
    # Reading_list_code
    row[5] = "#{course_code[5]}_RL"
    # Reading list name
    row[6] = list.name
    # Reading List Description
    row[7] = list.description
    # Reading lists Status
    row[8] = list_status
    # RLStatus
    row[9] = rl_status
    # visibility
    row[10] = list_visibility
    # owner_user_name
    row[11] = list_owner ? list_owner.username : ''
    # section_name
    row[12] = section_name
    # section_description
    row[13] = section_description
    # section_start_date
    row[14] = section_start_date
    # section_end_date
    row[15] = section_end_date
    # citation_secondary_type
    row[16] = citation_type(resource)
    # citation_status
    row[17] = citation_status
    # citation_tags
    row[18] = citation_tags(item)
    if resource
      # citation_originating_system_id
      row[19] = resource.citation_local_control_number
      # citation_title
      row[20] = resource.citation_title || item.title
      # citation_journal_title
      row[21] = resource.journal_title
      # citation_author
      row[22] = citation_authors(resource)
      # citation_publication_date
      row[23] = resource.citation_date
      # citation_edition
      row[24] = resource.citation_edition
      # citation_isbn
      row[25] = resource.citation_isbn10 || resource.citation_isbn13
      # citation_issn
      row[26] = resource.citation_issn
      # citation_place_of_publication
      row[27] = resource.citation_place_of_publication
      # citation_publisher
      row[28] = resource.citation_publisher
      # citation_volume
      row[29] = resource.citation_volume
      # citation_issue
      row[30] = resource.citation_issue
      # citation_pages
      row[31] = resource.citation_page
      # citation_start_page
      row[32] = resource.citation_page_start
      # citation_end_page
      row[33] = resource.citation_page_end
      # citation_doi
      row[34] = resource.citation_doi
      # citation_chapter
      row[35] = resource.chapter_title
      # citation_source
      row[36] = resource.citation_url
    else
      row[19] = item.local_control_number
      row[20] = item.title
      row[21] = ''
      row[22] = ''
      row[23] = ''
      row[24] = ''
      row[25] = ''
      row[26] = ''
      row[27] = ''
      row[28] = ''
      row[29] = ''
      row[30] = ''
      row[31] = ''
      row[32] = ''
      row[33] = ''
      row[34] = ''
      row[35] = ''
      row[36] = ''
    end

    # citation_start_page
    row[32] = ''
    # citation_end_page
    row[33] = ''
    # citation_note
    row[37] = item.library_note
    # additional_person_name
    row[38] = '' # TODO: What's the use case for this?
    # citation_public_note
    row[39] = item.student_note
    # external_system_id
    row[40] = '' # TODO: What's the correct value for this?

    # Return the row
    row

  end

  def citation_authors(resource)
    authors = resource.authors
    if authors.nil?
      ''
    elsif authors.is_a?(Array)
      authors.join('; ')
    else
      authors.to_s
    end
  end

  def citation_tags(item)
    tags = []
    # Infer tag from importance
    importance = item.importance ? item.importance.downcase : nil
    case importance
      when 'essential'
        tags.push('ESS')
      when 'optional'
        tags.push('OPT')
      when 'recommended'
        tags.push('REC')
      when 'suggested for student purchase'
        tags.push('SSP')
    end
    # May want to infer tag from enclosing sections
    tags.join(',')
  end

  def citation_type(resource)
    result = resource && resource.type ? resource.type.split('/')[-1] : nil
    if result
      result.delete!(' ')
      result.upcase!
    end
    result
  end

  def clear
    @@email.clear
    @@email = nil
    @@ldap.clear
    @@ldap = nil
  end

  def get_aspire_api
    @@mutex_aspire_api.synchronize do
      return @@aspire_api if @@aspire_api
      @@aspire_api = LegantoSync::ReadingLists::Aspire::API.new(@@aspire_client_id, @@aspire_secret, @@aspire_tenant,
                                                                tenancy_root: @@aspire_tenancy_root)
    end
    @@aspire_api
  end

  def get_courses
    # Build a mapping of { module code => { year => [course-codes] } }
    course_codes = {}
    CSV.foreach(@course_file, {col_sep: "\t"}) do |row|
      prefix, module_code, year, cohort = row[0].split('-')
      # Course fields = [course-code, section-id, searchable-id1, searchable-id2, searchable-id3, course-mnemonic]
      course_fields = [row[0], row[2], row[14], row[15], row[16], row[14]]
      course_id = "M#{module_code}"
      course_year = row[13].to_i
      course_codes[course_id] = {} unless course_codes.has_key?(course_id)
      course_code = course_codes[course_id]
      if course_code[course_year]
        course_code[course_year].push(course_fields)
      else
        course_code[course_year] = [course_fields]
      end
    end

    course_codes

  end

  def get_email
    @@mutex_email.synchronize do
      return @@email if @@email
      @@email = LegantoSync::ReadingLists::Aspire::EmailSelector.new(@@email_conf, @@email_map)
    end
    @@email
  end

  def get_ldap
    @@mutex_ldap.synchronize do
      return @@ldap if @@ldap
      @@ldap = LegantoSync::ReadingLists::Aspire::LDAPLookup.new(@@ldap_host, @@ldap_user, @@ldap_password, @@ldap_base)
    end
    @@ldap
  end

  def get_reading_list(list_id)

    # Create the output directory for the list
    dir = "#{@dir_aspire}/#{list_id}"
    begin
      Dir.mkdir(dir)
    rescue Errno::EEXIST
      # Ignore
    end

    # Get the list data
    uri = list_uri(list_id)
    list = @factory.get(uri)

  end

  def get_users(clear = false)
    email = self.get_email
    ldap = self.get_ldap
    @@mutex_users.synchronize do
      return @@users if @@users
      @@users = LegantoSync::ReadingLists::Aspire::UserLookup.new(email_selector: email, filename: @@users_file,
                                                                  ldap_lookup: ldap)
      if clear
      end
    end
    @@users
  end

  def list_uri(list_id)
    "#{@@aspire_tenancy_root}/lists/#{list_id}"
  end

  def write_reading_list(csv, list, courses, all: false)
    year = list.time_period.year
    list.modules.each do |mod|
      # Get the course codes applicable to this module/year (i.e. all cohorts for the module/year)
      course_codes = courses[mod.code]
      course_codes = course_codes ? course_codes[year] : nil
      next if course_codes.nil? || course_codes.empty?
      course_codes.each do |course_code|
        list.each_item do |item|
          csv << self.alma_reading_list_loader_row(list, item, course_code) if all || item.resource
        end
      end
    end
  end

end