require "./spec_helper"
require "../src/krikri_playbook_generator/preflight"

module KrikriPlaybookGenerator
  describe Preflight do
    it "passes when both engines resolve" do
      ls = Process.find_executable("ls")
      refute_nil(ls)
      Preflight.check!("ls", ls.as(String))
    end

    it "raises listing ansible-playbook when only it is missing" do
      ls = Process.find_executable("ls").as(String)
      err = assert_raises(PreflightError) { Preflight.check!("definitely-not-a-real-binary", ls) }
      msg = err.message || ""
      assert(msg.includes?("ansible-playbook"))
      refute(msg.includes?("krikri-playbook"))
    end

    it "raises listing krikri-playbook when only it is missing" do
      err = assert_raises(PreflightError) { Preflight.check!("ls", "/nonexistent/krikri-playbook") }
      msg = err.message || ""
      assert(msg.includes?("krikri-playbook"))
      refute(msg.includes?("ansible-playbook"))
    end

    it "raises listing both when both are missing" do
      err = assert_raises(PreflightError) { Preflight.check!("definitely-not-a-real-binary", "/nonexistent/krikri-playbook") }
      msg = err.message || ""
      assert(msg.includes?("ansible-playbook"))
      assert(msg.includes?("krikri-playbook"))
    end
  end
end
