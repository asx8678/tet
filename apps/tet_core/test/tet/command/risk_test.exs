defmodule Tet.Command.RiskTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.Command.Risk

  describe "classify/1" do
    test "classifies :critical for rm -rf /" do
      assert Risk.classify("rm -rf /") == :critical
    end

    test "classifies :critical for rm -rf /*" do
      assert Risk.classify("rm -rf /*") == :critical
    end

    test "classifies :critical for dd commands" do
      assert Risk.classify("dd if=/dev/zero of=/dev/sda bs=4M") == :critical
    end

    test "classifies :critical for format commands" do
      assert Risk.classify("format /dev/sda1") == :critical
    end

    test "classifies :critical for mkfs commands" do
      assert Risk.classify("mkfs.ext4 /dev/sda1") == :critical
    end

    test "classifies :critical for DROP TABLE" do
      assert Risk.classify("DROP TABLE users;") == :critical
    end

    test "classifies :critical for DROP DATABASE" do
      assert Risk.classify("DROP DATABASE production;") == :critical
    end

    test "classifies :high for DELETE without WHERE" do
      assert Risk.classify("DELETE FROM users") == :high
    end

    test "classifies :critical for mass deletes with find" do
      assert Risk.classify("find . -name '*.log' -delete") == :critical
    end

    test "classifies :critical for xargs rm" do
      assert Risk.classify("find . -name '*.tmp' | xargs rm") == :critical
    end

    test "classifies :high for TRUNCATE TABLE" do
      assert Risk.classify("TRUNCATE TABLE users;") == :high
    end

    test "classifies :high for rm file" do
      assert Risk.classify("rm file.txt") == :high
    end

    test "classifies :high for chmod 777" do
      assert Risk.classify("chmod 777 script.sh") == :high
    end

    test "classifies :high for chmod 777-like patterns" do
      assert Risk.classify("chmod 777 /path/to/file") == :high
    end

    test "classifies :high for chown -R" do
      assert Risk.classify("chown -R user:group /some/path") == :high
    end

    test "classifies :high for UPDATE without WHERE" do
      assert Risk.classify("UPDATE users SET admin = true") == :high
    end

    test "classifies :high for DELETE with WHERE 1=1" do
      assert Risk.classify("DELETE FROM users WHERE 1=1") == :high
    end

    test "classifies :medium for sed -i" do
      assert Risk.classify("sed -i 's/foo/bar/' config.txt") == :medium
    end

    test "classifies :medium for cat >" do
      assert Risk.classify("cat > output.txt") == :medium
    end

    test "classifies :medium for file redirect >" do
      assert Risk.classify("echo 'hello' > file.txt") == :medium
    end

    test "classifies :medium for file append >>" do
      assert Risk.classify("echo 'hello' >> file.txt") == :medium
    end

    test "classifies :medium for apt install" do
      assert Risk.classify("apt-get install nginx") == :medium
    end

    test "classifies :medium for brew install" do
      assert Risk.classify("brew install wget") == :medium
    end

    test "classifies :medium for npm install" do
      assert Risk.classify("npm install express") == :medium
    end

    test "classifies :medium for pip install" do
      assert Risk.classify("pip install requests") == :medium
    end

    test "classifies :medium for service restart" do
      assert Risk.classify("service nginx restart") == :medium
    end

    test "classifies :medium for systemctl restart" do
      assert Risk.classify("systemctl restart nginx") == :medium
    end

    test "classifies :medium for sudo" do
      assert Risk.classify("sudo apt update") == :medium
    end

    test "classifies :low for mkdir" do
      assert Risk.classify("mkdir new_dir") == :low
    end

    test "classifies :low for touch" do
      assert Risk.classify("touch new_file.txt") == :low
    end

    test "classifies :low for cp" do
      assert Risk.classify("cp file.txt backup.txt") == :low
    end

    test "classifies :low for mv" do
      assert Risk.classify("mv file.txt new_name.txt") == :low
    end

    test "classifies :low for git add" do
      assert Risk.classify("git add .") == :low
    end

    test "classifies :low for git commit" do
      assert Risk.classify("git commit -m 'fix'") == :low
    end

    test "classifies :low for mix format" do
      assert Risk.classify("mix format") == :low
    end

    test "classifies :low for mix compile" do
      assert Risk.classify("mix compile") == :low
    end

    test "classifies :low for SELECT" do
      assert Risk.classify("SELECT * FROM users") == :low
    end

    test "classifies :none for ls" do
      assert Risk.classify("ls -la") == :none
    end

    test "classifies :none for pwd" do
      assert Risk.classify("pwd") == :none
    end

    test "classifies :none for echo" do
      assert Risk.classify("echo hello world") == :none
    end

    test "classifies :none for cat" do
      assert Risk.classify("cat README.md") == :none
    end

    test "classifies :none for simple git status" do
      assert Risk.classify("git status") == :none
    end
  end

  describe "requires_gate?/1" do
    test "returns true for :high" do
      assert Risk.requires_gate?(:high) == true
    end

    test "returns true for :critical" do
      assert Risk.requires_gate?(:critical) == true
    end

    test "returns false for :none" do
      assert Risk.requires_gate?(:none) == false
    end

    test "returns false for :low" do
      assert Risk.requires_gate?(:low) == false
    end

    test "returns false for :medium" do
      assert Risk.requires_gate?(:medium) == false
    end
  end

  describe "risk_label/1" do
    test "returns human-readable labels" do
      assert Risk.risk_label(:none) == "No risk — read-only"
      assert Risk.risk_label(:low) == "Low risk — minimally invasive"
      assert Risk.risk_label(:medium) == "Medium risk — potentially destructive"
      assert Risk.risk_label(:high) == "High risk — destructive operation"
      assert Risk.risk_label(:critical) == "Critical risk — system-destructive"
    end
  end

  describe "levels/0" do
    test "returns all valid levels" do
      assert Risk.levels() == [:none, :low, :medium, :high, :critical]
    end
  end
end
