/*
 * libdpkg - Debian packaging suite library routines
 * ar.c - primitives for ar handling
 *
 * Copyright © 2010 Guillem Jover <guillem@debian.org>
 *
 * This is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#ifndef LIBDPKG_AR_H
#define LIBDPKG_AR_H

#include <ar.h>

#include <dpkg/macros.h>

DPKG_BEGIN_DECLS

#define DPKG_AR_MAGIC "!<arch>\n"

void dpkg_ar_normalize_name(struct ar_hdr *arh);

DPKG_END_DECLS

#endif /* LIBDPKG_AR_H */
