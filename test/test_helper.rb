require_relative "simplecov_config"

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

require "capybara/rails"
require "minitest/hooks/test"
require "minitest/mock"
require "mocha/minitest" # need to be after rails/test_help
require "sidekiq/testing"
require "webmock"
require "httpx/adapters/webmock" # https://honeyryderchuck.gitlab.io/httpx/wiki/Webmock-Adapter
require "webmock/minitest"
require "faker"

require "knapsack_pro"
knapsack_pro_adapter = KnapsackPro::Adapters::MinitestAdapter.bind
knapsack_pro_adapter.set_test_helper_path(__FILE__)

Rails.root.glob("test/support/**/*.rb").sort.each { |f| require f }

PDF_PATH = "test/support/files/test.pdf".freeze
PNG_PATH = "test/support/files/test.png".freeze
DOCX_PATH = "test/support/files/test.docx".freeze
# Legal valid SSN for testing https://www7.skatteverket.se/portal/apier-och-oppna-data/utvecklarportalen/oppetdata/Test%C2%AD%C2%ADpersonnummer
VALID_SE_SSN = "199001012385".freeze
# https://kehittajille.suomi.fi/tjanster/identifikation/teknisk-implementering/anslutning-till-testmiljon/identifieringsverktyg-i-testmiljon
VALID_FI_SSN = "010280-952L".freeze
# This is needed during tests to avoid strange behaviour.
# https://github.com/markets/invisible_captcha/issues/25
InvisibleCaptcha.timestamp_enabled = false

# https://knapsackpro.com/faq/question/how-to-use-simplecov-in-queue-mode
KnapsackPro::Hooks::Queue.before_queue do |queue_id|
  SimpleCov.command_name("minitest_ci_node#{KnapsackPro::Config::Env.ci_node_index}")
end

# Manually output SimpleCov results
KnapsackPro::Hooks::Queue.after_queue do |queue_id|
  SimpleCov.result&.format!
end

WebMock.disable_net_connect!(
  allow_localhost: true
)

begin
  Shrine.storages[:store].bucket.create unless Shrine.storages[:store].bucket.exists?
rescue
  puts("WARNING: Shrine buckets not able to set up - maybe MinIO is not running")
end

Minitest.after_run do
  Shrine.storages[:store].clear! if ENV["CI"].blank?
rescue
  puts("WARNING: Shrine storage was not cleared - maybe MinIO is not running")
end

class ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ElasticsearchTesting
  include FactoryBot::Syntax::Methods
  include BulletTesting
  include DownStubbing
  include ValidEmail2Stubbing
  include VisualbyStubbing
  include Minitest::Hooks
  include DefaultRolesHelper
  include PermissionsHelper

  ActiveRecord::Migration.maintain_test_schema!

  parallelize(workers: ENV.fetch("PARALLEL_WORKERS", :number_of_processors))
  parallelize_setup do |worker|
    SimpleCov.command_name("#{SimpleCov.command_name}-#{worker}")
    SemanticLogger.reopen
  end

  parallelize_teardown do |worker|
    SimpleCov.result&.format!
  end

  # Setup all fixtures in test/fixtures/*.(yml|csv) for all tests in alphabetical order.
  #
  # Note: You'll currently still have to declare fixtures explicitly in integration tests
  # -- they do not yet inherit this setting
  fixtures :all

  def before_all
    super
  end

  setup do
    ApplicationMailer.deliveries.clear
    Aws.config.update(stub_responses: true)
    WebMock.disable_net_connect!(
      allow_localhost: true
    )
    clear_enqueued_jobs
    travel_back
    valid_email2_mx_stub

    # Premailer will try to download font css as well
    ThemeConfig.allowed_themes.filter_map { |name| Theme.new(theme_name: name).email_font_family_url }
      .uniq
      .each { |url| stub_request(:get, url).to_return(status: 200) }

    ActionController::Base.allow_forgery_protection = false
    SearchIndexJob.stubs(:perform_later).returns(nil)
    [PdfGenerator, AnnualReportPdfGenerator].each do |klass|
      klass.any_instance.stubs(:generate).returns(
        File.read(PDF_PATH)
      )
      klass.any_instance.stubs(:generate_with_feedback).returns(
        {
          content: File.read(PDF_PATH),
          logs: [],
          error: ""
        }
      )
    end
  end

  teardown do
    Sidekiq::Worker.clear_all
    bullet_teardown
    travel_back
    valid_email2_mx_unstub
    [PdfGenerator, AnnualReportPdfGenerator].each do |klass|
      klass.any_instance.unstub(:generate)
      klass.any_instance.unstub(:generate_with_feedback)
    end
  end

  # Helper methods to switch to AnyFixture in the future
  def base_membership
    unless CompanyRole.exists?(owner_type: "Company", owner_id: nil, title: "admin")
      admin_role = create(:company_role, owner_type: "Company", owner_id: nil)

      permission_data = []
      all_scopes = YAML.load_file(Rails.root.join("config/data/permission_scopes.yml"))
      all_scopes.filter { |scope| scope.start_with?("company") }.each do |scope|
        permission_data << {subject_id: admin_role.id, subject_type: "CompanyRole", scope: scope, action: "read"}
        permission_data << {subject_id: admin_role.id, subject_type: "CompanyRole", scope: scope, action: "update"}
      end
      Permission.upsert_all(permission_data)
    end

    @base_membership ||= create(
      :membership,
      :board_member,
      function: :chairman,
      policy_level: :admin,
      company: create(
        :company,
        title: "Base Company",
        plan: Plan.basic
      ),
      user: create(
        :user,
        name: "Base User",
        email: "base_user@boardeaser.com"
      )
    )
  end

  def base_company
    base_membership&.company
  end

  def base_user
    base_membership&.user
  end

  def base_user_w_financials
    user = base_user

    create(
      :access_token,
      vendor: Visualby::VENDOR,
      owner: user,
      username: "#{user.uuid}@boardeaser.com",
      password: SecureRandom.hex(16),
      expires_at: 1.day.from_now
    )

    base_membership.update!(
      financials_uuid: SecureRandom.uuid,
      corporate_group_uuid: SecureRandom.uuid,
      financials_link_created_at: Time.current,
      financials_corporate_group_created_at: Time.current
    )

    base_membership.company.update!(
      financials_uuid: SecureRandom.uuid,
      corporate_group_uuid: SecureRandom.uuid
    )

    user
  end

  def admin_panel_membership_w_financials
    admin_panel_membership = create(
      :admin_panel_membership,
      policy_level: :admin
    )

    admin_panel_membership.update!(
      financials_uuid: SecureRandom.uuid,
      corporate_group_uuid: SecureRandom.uuid,
      financials_link_created_at: Time.current,
      financials_corporate_group_created_at: Time.current
    )

    create(
      :access_token,
      vendor: Visualby::VENDOR,
      owner: admin_panel_membership.user,
      username: "#{admin_panel_membership.user.uuid}@boardeaser.com",
      password: SecureRandom.hex(16),
      expires_at: 1.day.from_now
    )

    admin_panel_membership.admin_panel.update!(
      financials_uuid: SecureRandom.uuid
    )
    admin_panel_membership
  end

  def prepare_feature(name:)
    Feature.find_by(name: name) || create(:feature, name: name)
  end

  def prepare_feature_subscription(company:, feature_name:)
    feature = prepare_feature(name: feature_name)
    company.subscriptions.find_by(subscribed: feature) || create(:feature_subscription, subscribed: feature, company: company)
  end

  def set_policy_level!(level, membership = @membership)
    update_membership!({policy_level: level}, membership)
  end

  def update_membership!(attributes = {}, membership = @membership)
    membership.update!(attributes)

    if membership.is_a?(AdminPanelMembership)
      AdminPanelPermissionsBuilderService.new(membership).perform
      membership.admin_panel.admin_companies.each do |admin_company|
        CompanyPermissionsBuilderService.new(membership.user, admin_company.company).perform
        AdminCompanyPermissionsBuilderService.new(membership.user, admin_company).perform
      end
    elsif membership.admin_company.present?
      CompanyPermissionsBuilderService.new(membership.user, membership.real_company).perform
      AdminCompanyPermissionsBuilderService.new(membership.user, membership.admin_company).perform
    else
      CompanyPermissionsBuilderService.new(membership.user, membership.company).perform
    end

    membership.user.instance_variable_set(:@memberships_for, nil)
    membership.user.skip_background_work = false
  end

  def sign_in_to_manage(scopes: [])
    host!("manage.example.com")

    role = create(:manage_role)
    scopes.each do |scope|
      role.manage_permissions.create!(scope: scope, action: "read")
      if ManagePermission::GRANULAR_SCOPES.include?(scope)
        role.manage_permissions.create!(scope: scope, action: "create")
        role.manage_permissions.create!(scope: scope, action: "update")
        role.manage_permissions.create!(scope: scope, action: "delete")
      end
    end
    admin_user = create(:admin_user)
    admin_user.roles << role

    sign_in(admin_user)
    admin_user
  end

  # Override inspect because it is super long otherwise
  # Apparently changed in Ruby and under discussion
  # https://bugs.ruby-lang.org/issues/18285
  # Got the tip to override inspect by https://github.com/byroot
  def inspect
    "#{self.class.name} #{name}"
  end

  def perform_noticed
    perform_enqueued_jobs(only: [Noticed::EventJob, Noticed::DeliveryMethods::Email, ActionMailer::MailDeliveryJob]) do
      yield
    end
  end

  def perform_and_assert_emails_delivered(count:)
    perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
      assert_difference(-> { ActionMailer::Base.deliveries.size }, count) do
        yield
      end
    end
  end

  private

  def elevated_with_password(elevated_at: Time.current)
    Warden.on_next_request do |proxy|
      proxy.raw_session[:password_confirmed_at] = Time.current
    end
  end
end

class ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ::ExtraSignInHelpers # Adds possibility to sign in user with MFA and IDP

  fixtures :all

  def inertia_params
    # Find the inertia data to check for some props
    JSON.parse(response.parsed_body.at_xpath('//div[@id="app"]').attributes["data-page"].value)
  rescue
    nil
  end

  def with_rack_attack_enabled
    Rack::Attack.enabled = true
    Rails.application.config.action_controller.perform_caching = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rack::Attack.enabled = false
    Rails.application.config.action_controller.perform_caching = false
  end
end
