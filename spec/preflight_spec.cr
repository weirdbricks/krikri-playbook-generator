require "./spec_helper"

module KrikriPlaybookGenerator
  describe Preflight do
    it "passes when both engines resolve" do
      Preflight.check!("ls", Process.find_executable("ls").not_nil!)
    end

    it "raises listing ansible-playbook when only it is missing" do
      ex = expect_raises(PreflightError) { Preflight.check!("definitely-not-a-real-binary", Process.find_executable("ls").not_nil!) }
      ex.message.not_nil!.should contain("ansible-playbook")
      ex.message.not_nil!.should_not contain("krikri-playbook")
    end

    it "raises listing krikri-playbook when only it is missing" do
      ex = expect_raises(PreflightError) { Preflight.check!("ls", "/nonexistent/krikri-playbook") }
      ex.message.not_nil!.should contain("krikri-playbook")
      ex.message.not_nil!.should_not contain("ansible-playbook")
    end

    it "raises listing both when both are missing" do
      ex = expect_raises(PreflightError) { Preflight.check!("definitely-not-a-real-binary", "/nonexistent/krikri-playbook") }
      ex.message.not_nil!.should contain("ansible-playbook")
      ex.message.not_nil!.should contain("krikri-playbook")
    end
  end
end
