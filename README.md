# Whalebuilder 🐋
![Version][b1]
[![License][b2]](./LICENSE)

Build `.deb` packages inside a container.

Why use a container to build packages?

 * Because building occurs inside a container build dependencies and build
   cruft will not pollute your workstation.

 * Building is done in a clean and reproducible environment. So that it is
   possible to verify that a package can be built by others using the same
   environment[^1].

 * Allows building for other/newer/older distributions on the same machine.

The idea behind `whalebuilder` is to serve as an alternative for
[`pbuilder`][1]. But instead of using a chroot environment, it uses a
container. Where `pbuilder` provides tools for creating and maintaining chroot
environments here you would use any container creation/management software,
such as `podman` or `docker`, and `whalebuilder` simply builds the package
using those containers.

[1]: https://pbuilder-team.pages.debian.net/pbuilder/#aim


## Basics

Essentially, `whalebuilder` does three things:
 1. Launch a container and mount your current working directory.
 2. Install build dependencies.
 3. Run [`dpkg-buildpackage`][4].

Therefore, it basically works like a replacement for `dpkg-buildpackage` in
your local workflow. If you would normally run `dpkg-buildpackage -us -uc`,
you could instead run:

```
/path/to/whalebuilder.sh -- -us -uc
```

Note that options after a double dash '--' are passed verbatim to
`dpkg-buildpackage`.

By default `whalebuilder` will use the [`debian:sid-slim`][5] image. If you
wish to build a package, for example, for Ubuntu 22.04. You could run:

```
/path/to/whalebuilder.sh --image ubuntu:22.04 -- -us -uc
```

[4]: https://manpages.debian.org/unstable/dpkg-dev/dpkg-buildpackage.1.en.html
[5]: https://hub.docker.com/_/debian


## Advanced Usage

### Integration with [git-buildpackage][6]

Use the `--git-builder` option as follows when invoking `gbp buildpackage`:

```
gbp buildpackage --git-builder=/path/to/whalebuilder.sh
```

Note that `gbp buildpackage` is able to pass on options specifically for
`whalebuilder` like:

```
gbp buildpackage --git-builder=/path/to/whalebuilder.sh --image ubuntu:22.04
```

[6]: https://honk.sigxcpu.org/piki/projects/git-buildpackage/


### Reusing a Container

To speed up the build process you can first run `whalebuilder` but only
install build dependencies (using the `--no-build` option) and save the
container at that stage (using the `--save` option).

```
/path/to/whalebuilder.sh --no-build --save <image-name>
```

Next calls to `whalebuilder` in the form below will find the build
dependencies already installed and will only have to build the packages.

```
/path/to/whalebuilder.sh --image <image-name>
```

### Custom Build Dependencies

Option `--deps` allows specifying a folder. Any `.deb` packages in that folder
will be installed before performing the build.

By default, `whalebuilder` attempts to guess the dependencies required to
build the package based what's stated at the `debian/control` file. For this
it uses the `mk-build-deps` script from the [`devscripts`][7] package. This
implies that packages `devscripts` and `equivs` are installed by default in
the container. To disable this behavior use option `--no-auto-deps`.

```
/path/to/whalebuilder.sh --deps /path/to/deps --no-auto-deps
```

[7]: https://salsa.debian.org/debian/devscripts


### Other Features

For a for a full list of options:

```
/path/to/whalebuilder.sh --help
```

## Requirements

 * Bash
 * [Podman][2] or [Docker][3]

[2]: https://podman.io/
[3]: https://www.docker.com/


## Contributing & Road Map

Contributions, issues and feature requests are welcome.

Current feature wish list:
 * Testing
 * Support `autopkgtest`
 * Support `piuparts`


## License

```
Copyright © 2023 Rock Storm

WhaleBuilder is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

WhaleBuilder is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
WhaleBuilder. If not, see <https://www.gnu.org/licenses/>.
```


## Credits

Heavily inspired on [docker-deb-builder][8] by [Tero Saarni][9].

[8]: https://github.com/tsaarni/docker-deb-builder
[9]: https://github.com/tsaarni


[^1]: Provided the same (build) dependencies are installed.


[b1]: https://img.shields.io/github/v/tag/rockstorm101/whalebuilder?include_prereleases&label=version
[b2]: https://img.shields.io/github/license/rockstorm101/whalebuilder
