require "test_helper"

class NotesControllerTest < ActionDispatch::IntegrationTest
  test "GET #index" do
    get notes_path
    assert_response :not_acceptable
  end
end
