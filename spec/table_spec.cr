require "./spec_helper"
require "../src/krikri_playbook_generator/table"

module KrikriPlaybookGenerator
  describe Table do
    it "pads every column to its widest cell and draws the header separator" do
      text = Table.render(["module", "n"], [["copy", "2"], ["postgresql_privs", "12"]])

      assert_equal(<<-TABLE.rstrip, text)
┌──────────────────┬────┐
│ module           │ n  │
├──────────────────┼────┤
│ copy             │ 2  │
│ postgresql_privs │ 12 │
└──────────────────┴────┘
TABLE
    end

    it "right-aligns only the named columns, headers stay left-aligned" do
      text = Table.render(["run", "module", "# of playbooks"],
        [["1", "copy", "2"], ["12", "apt", "10"]], right_align: ["run", "# of playbooks"])

      assert_equal(<<-TABLE.rstrip, text)
┌─────┬────────┬────────────────┐
│ run │ module │ # of playbooks │
├─────┼────────┼────────────────┤
│   1 │ copy   │              2 │
│  12 │ apt    │             10 │
└─────┴────────┴────────────────┘
TABLE
    end

    it "keeps a short row aligned by padding missing trailing cells" do
      text = Table.render(["a", "b"], [["x"]])

      assert_equal(<<-TABLE.rstrip, text)
┌───┬───┐
│ a │ b │
├───┼───┤
│ x │   │
└───┴───┘
TABLE
    end

    it "paints the table green on a terminal and leaves a piped report plain" do
      plain = Table.render(["module", "n"], [["copy", "2"]])
      refute_includes(plain, "\e[")

      previous = ENV["KRIKRI_FORCE_COLOR"]?
      begin
        ENV["KRIKRI_FORCE_COLOR"] = "1"
        colored = Table.render(["module", "n"], [["copy", "2"]])
      ensure
        if previous
          ENV["KRIKRI_FORCE_COLOR"] = previous
        else
          ENV.delete("KRIKRI_FORCE_COLOR")
        end
      end
      assert_includes(colored, "\e[32m")
      assert_includes(colored, "\e[32mcopy\e[0m")
      assert_equal(plain, colored.gsub(/\e\[[0-9;]*m/, ""))
    end
  end
end
