function dependency -d 'manage dependencies'

  # Load dependency
  function dep_plugin -d "Install or uninstall a fish plugin"
    switch "$argv[1]"
      case uninstall
        if type -q omf
          omf remove (basename $argv[2]) >/dev/null 2>&1
        else
          fisher rm (basename $argv[2]) >/dev/null 2>&1
        end
      case check
        if type -q omf
          omf list | string match -qr "\b$argv[2]\b"
        else
          fisher ls | string match -qr "\b$argv[2]\b"
        end
      case update
        if type -q omf
          if omf list | string match -qr "\b"(basename $argv[2])"\b"
            omf update $argv[2] >"$PREFIX"/tmp/dep_plugin 2>&1
            if grep -qE '(Error|Could not find)'"$PREFIX"/tmp/dep_plugin
              command rm "$PREFIX"/tmp/dep_plugin
              return 1
            end
            command sed -n \$p "$PREFIX"/tmp/dep_plugin
            command rm "$PREFIX"/tmp/dep_plugin
          else
            omf install $argv[2] 2>&1 | not string match -qr '^(Error|Could not install)'
          end
        else
          fisher add (basename $argv[2]) 2>&1 \
          | not string match -qr 'cannot (add|stat)'
        end
      case '*'
        type -t (basename $argv) 2>/dev/null | string match -q function
        and return 0
        if type -q omf
          omf list | not string match -qr "\b"(basename $argv)"\b"
          and omf install $argv 2>&1 \
          | not string match -qr '^(Error|Could not install)'
        else
          fisher ls | not string match -qr "\b"(basename $argv)"\b"
          and fisher add $argv 2>&1 \
          | not string match -qr 'cannot (add|stat)'
        end
    end
  end
  dep_plugin https://gitlab.com/lusiadas/feedback

  # Parse argument
  function dep_main
    if not argparse -x (string join -- ' -x ' i,{u,r,f} u,{r,f} | string split ' ') 'i/install' 'u/update=' 'r/remove' 'N/npm=+' 'f/force=+' 'p/pip=+' 'P/plugin=+' -- $argv 2>"$PREFIX"/tmp/err
      err (grep -m 1 -oP '(?<=: ).+' "$PREFIX"/tmp/err)
      return 1
    end

    # Check for available permissions
    set -l sudo
    if id -u $USER | string match -qv 0
      if id -g $USER | string match -qe sudo
        type -qf sudo
        and set sudo sudo
      end
    end

    # Check for a default package manager
    set -l verify
    set -l install
    set -l update
    set -l remove
    if type -qf apt
      set verify "dpkg -s"
      set install 'apt install -y'
      set update 'apt upgrade -y'
      set remove "apt remove -y"
    else if type -qf pacman
      set verify 'pacman -Qi'
      set install 'pacman -S --noconfirm'
      set update 'pacman -S --noconfirm'
      set remove 'pacman -Rs --noconfirm'
    else if type -qf zypper
      set verify 'rpm -q'
      set install 'zypper in -y'
      set update 'zypper up -y'
      set remove 'zypper rm -y'
    else if type -qf yum
      set verify 'rpm -q'
      set install 'yum install -y'
      set update 'yum update -y'
      set remove 'yum remove -y'
    else if type -qf dnf
      set verify 'rpm -q'
      set install 'dnf install -y'
      set update 'dnf upgrade -y'
      set remove 'dnf remove -y'
    else if type -qf emerge
      set verify 'emerge -p'
      set install 'emerge'
      set update 'emerge -DuN'
      set remove 'emerge -c'
    else if test "$argv"
      test (count $argv) -eq 1
      and err "A package manager wasn't found to handle package |$argv|"
      or err "A package manager wasn't found to handle packages |"(string join '|, |' $argv)"|"
      reg 'Ignoring... '
      set --erase argv
    end

    # Search for an specific package manager
    if test -n "$_flag_pip" -o -n "$_flag_npm"
      set -l flags _flag_pip pip python _flag_npm npm nodejs
      for i in 1 4
        set --query $flags[$i]
        or continue
        if not type -qf $flags[(math $i + 1)]
          set -l failed
          if test -z "$install"
            set failed true
          else if read -n 1 -p "wrn -n \"|"$flags[(math $i + 2)]"| isn't installed. Install it before proceding with installation? [y/n]: \"" | string match -viq y
            set failed true
          end
          if test -z "$failed"
            dim -on "Installing |"$flags[(math $i + 2)]"|... "
            eval $install $flags[(math $i + 2)] >/dev/null 2>&1
            and reg -o "|"$flags[(math $i + 2)]"| installed"
            or set failed true
          end
          if test "$failed"
            string match -q $flags[$i] _flag_pip
            and set -l packages $_flag_pip
            or set -l packages $_flag_npm
            err -o "|"$flag[(math $i + 2)]"| isn't installed. Cancelling the installation of |"(string join '|, |' $packages)"|"
            set --erase $flags[$i]
          end
        end
        set --query _flag_update
        or continue
        string match $flags[$i] _flag_pip
        and pip install --upgrade pip >/dev/null
        or npm update npm -g
      end
    end

    # Check if package is installed
    test -n "$_flag_update" -o -n "$_flag_uninstall"
    and dim -n "Checking for dependencies... "
    set -l dependencies (printf '%s\n' $argv $_flag_pip $_flag_npm $_flag_plugin $_flag_force | sort | uniq)
    for dependency in $dependencies
      if type -q (basename $dependency)
        set -a installed $dependency
        continue
      end
      if contains (basename $dependency) $argv
        if eval $verify $dependency >/dev/null 2>&1
          set -a installed $dependency
          continue
        end
      end
      if contains (basename $dependency) $_flag_plugin $argv
        if dep_plugin check $dependency
          set -a installed $dependency
          continue
        end
      end
      if contains (basename $dependency) $_flag_pip $argv
        if pip show -q $dependency
          set -a installed $dependency
          continue
        end
      end
      if contains (basename $dependency) $flag_npm $argv
        if npm list -g | string match -qe $dependency
          set -a installed $dependency
          continue
        end
      end
      set not_installed $not_installed $dependency
    end

    # Remove dependencies
    if test -n "$_flag_uninstall" -a -n "$installed"

      # Offer to uninstall dependencies
      echo -en \r(tput el)
      if test (count $installed) -eq 1
        read -n 1 -p "wrn -n \"Uninstall dependency |$installed|? [y/n]: \"" | string match -qir y
      else
        read -n 1 -p "wrn -n 'Uninstall some dependencies as well? [y/n]: '" | string match -qir y
      end
      or return 0

      # List available dependencies
      if test (count $installed) -gt 1
        for i in (seq (count $installed))
          echo $i. $installed[$i]
        end
        printf '%s\n' (math (count $installed) + 1)'. all' \
        (math (count $installed) + 2)'. cancel'

        # Select dependencies to be removed
        read -n 1 -lP 'Which? [list one or more]: ' opt
        string match -qr -- "[^1-"(math (count $installed) + 1)"]" $opt
        and return 0
        test $opt -le (count $installed)
        and set installed $installed[$opt]
      end

      # Find the appropriate package manager to uninstall
      for dependency in $installed
        dim -n "Uninstalling |$dependency|... "
        if contains $dependency $argv
          if eval "$sudo" $uninstall $dependency >/dev/null 2>&1
            reg -o "|$dependency| removed."
            continue
          end
        end
        if contains $dependency $_flag_pip $argv
          if command pip list | string match -qr '^youtube-dl\b'
            command pip uninstall -y $dependency >/dev/null 2>&1
            reg -o "|$dependency| removed."
            continue
          end
        end
        if contains $dependency $_flag_plugin
          if dep_plugin uninstall $_flag_plugin
            reg -o "|$dependency| removed."
            continue
          end
        end
        if contains $dependency $flag_npm
          if command npm list -g | string match -qr "\b$dependency(?=@)"
            command npm uninstall -g $dependency >/dev/null 2>&1
            reg -o "|$dependency| removed."
            continue
          end
        end
        if contains $dependency $_flag_force
          if command rm $dependency >/dev/null 2>&1
            reg -o "|$dependency| removed."
            continue
          end
        end
        err -o "Failed to uninstall |$dependency|"
      end

    # Update or install dependencies
    else
      if test -z "$not_installed"
        set --query _flag_update
        or return 0
      end

      # Ask for confirmation
      set --query _flag_update
      and set -l packages $dependencies
      or set -l packages $not_installed
      if set --query _flag_name
        if test (count $packages) -eq 1
          read -n 1 -p "wrn -n \"Plugin |$_flag_name| requires dependency |$packages|. Install it? [y/n]: \"" | string match -qir y
        else
          read -n 1 -p "wrn -n \"Plugin |$_flag_name| requires dependency |$packages|. Install it? [y/n]: \"" | string match -qir y
        end
      end
      or return 1

      # Find appropriate package manager to install
      set -l failed
      for dependency in $packages
        set --query _flag_update
        and dim -on "Updating |$dependency|... "
        or dim -on "Installing |$dependency|... "
        if contains $dependency $argv
          if set --query _flag_update
            eval "$sudo" $update $dependency 2>/dev/null \
            | string match -e version
            and continue
          else if eval "$sudo" $install $dependency >/dev/null 2>&1
            reg -o "|$dependency| added."
            continue
          end
        end
        if contains $dependency $_flag_pip $argv
          if set --query _flag_update
            command pip install --upgrade $dependency 2>/dev/null \
            | command sed -n 1p
            and continue
          else if command pip install $dependency >/dev/null 2>&1
            reg -o "|$dependency| added."
            continue
          end
        end
        if contains $dependency $_flag_plugin $argv
          if set --query _flag_update
            dep_plugin update $dependency
            and continue
          else if dep_plugin $dependency
            reg -o "|$dependency| added."
            continue
          end
        end
        if contains $dependency $_flag_npm $argv
          if set --query _flag_update
            npm install -g $dependency >/dev/null 2>&1 \
            | string match -ar '(^\+ .+|.*updated.+)' | uniq
            and continue
          else if command npm install -g $dependency >/dev/null 2>&1
            reg -o "|$dependency| added."
            continue
          end
        end
        set --query _flag_update
        and err -o "Failed to update |$dependency|"
        or err -o "Failed to install |$dependency|"
        set failed true
      end
      test -z "$failed"
    end
  end

  # Call main function and unload auxiliary functions before finishing
  dep_main $argv
  set -l exit_status $status
  functions -e (functions | string match -ar '^dep_.+')
  test $exit_status -eq 0
end
