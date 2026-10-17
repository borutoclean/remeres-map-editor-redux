//////////////////////////////////////////////////////////////////////
// This file is part of Remere's Map Editor
//////////////////////////////////////////////////////////////////////
// Remere's Map Editor is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Remere's Map Editor is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <http://www.gnu.org/licenses/>.
//////////////////////////////////////////////////////////////////////

#include "app/main.h"
#include "lua_api_image.h"
#include "ui/gui.h"
#include "rendering/core/graphics.h"
#include "rendering/core/game_sprite.h"
#include "ui/icons/sprite_icon_service.h"
#include "rendering/core/normal_image.h"
#include "game/items.h"
#include <filesystem>
#include <cstring>
#include <vector>
#include <algorithm>
#include <array>
#include <limits>
#include <cmath>
#include <cstdlib>
#include "lua_script_manager.h"
#include "util/file_system.h"

namespace LuaAPI {

	static bool imagesHaveSamePixels(const wxImage& lhs, const wxImage& rhs) {
		if (lhs.IsOk() != rhs.IsOk()) {
			return false;
		}
		if (!lhs.IsOk()) {
			return true;
		}
		if (lhs.GetWidth() != rhs.GetWidth() || lhs.GetHeight() != rhs.GetHeight()) {
			return false;
		}
		if (lhs.HasAlpha() != rhs.HasAlpha()) {
			return false;
		}

		const size_t rgbBytes = static_cast<size_t>(lhs.GetWidth()) * static_cast<size_t>(lhs.GetHeight()) * 3;
		if (std::memcmp(lhs.GetData(), rhs.GetData(), rgbBytes) != 0) {
			return false;
		}
		if (lhs.HasAlpha()) {
			const size_t alphaBytes = static_cast<size_t>(lhs.GetWidth()) * static_cast<size_t>(lhs.GetHeight());
			if (std::memcmp(lhs.GetAlpha(), rhs.GetAlpha(), alphaBytes) != 0) {
				return false;
			}
		}
		return true;
	}

	LuaImage::LuaImage() :
		spriteId(0), spriteSource(false) {
		// Empty image
	}

	LuaImage::LuaImage(const std::string& path) :
		filePath(path), spriteId(0), spriteSource(false) {

		if (path.empty()) {
			return;
		}

		namespace fs = std::filesystem;
		fs::path scriptsPath = fs::weakly_canonical(LuaScriptManager::getInstance().getScriptsDirectory());
		fs::path dataPath = fs::weakly_canonical(FileSystem::GetDataDirectory().ToStdString());
		fs::path execPath = fs::weakly_canonical(FileSystem::GetExecDirectory().ToStdString());
		std::vector<fs::path> lookupRoots;

		try {
			std::string activeScriptDir = LuaScriptManager::getInstance().getEngine().getState()["SCRIPT_DIR"].get_or(std::string(""));
			if (!activeScriptDir.empty()) {
				fs::path packagePath = fs::path(activeScriptDir);
				if (fs::exists(packagePath)) {
					if (fs::is_regular_file(packagePath)) {
						packagePath = packagePath.parent_path();
					}
					lookupRoots.push_back(fs::weakly_canonical(packagePath));
				}
			}
		} catch (...) {
			// Ignore failures and continue with the default search roots.
		}
		lookupRoots.push_back(scriptsPath);
		lookupRoots.push_back(dataPath);
		lookupRoots.push_back(execPath);

		fs::path fullPath;
		bool allowed = false;

		try {
			fs::path p(path);
			if (p.is_absolute()) {
				fullPath = fs::weakly_canonical(p);
				// Check if absolute path is within allowed roots
				for (const auto& root : lookupRoots) {
					auto relative = fullPath.lexically_relative(root);
					if (!relative.empty() && relative.string().find("..") == std::string::npos) {
						if (fs::is_regular_file(fullPath)) {
							allowed = true;
							break;
						}
					}
				}
			} else {
				// For relative paths, try anchoring to each root
				for (const auto& root : lookupRoots) {
					fs::path candidate = fs::weakly_canonical(root / p);
					auto relative = candidate.lexically_relative(root);
					if (!relative.empty() && relative.string().find("..") == std::string::npos) {
						if (fs::is_regular_file(candidate)) {
							fullPath = candidate;
							allowed = true;
							break;
						}
					}
				}
			}
		} catch (...) {
			printf("[Lua Security] Failed to canonicalize image path: %s\n", path.c_str());
			return;
		}

		if (!allowed) {
			printf("[Lua Security] Blocked image path outside allowed directories: %s\n", path.c_str());
			return;
		}
		
		filePath = fullPath.string();

		if (!filePath.empty()) {
			image.LoadFile(wxString(filePath));
		}
	}

	LuaImage::LuaImage(int id, bool isItemSprite) :
		spriteId(0), spriteSource(false) {
		if (isItemSprite) {
			// Get sprite ID from item type
			if (g_items.typeExists(id)) {
				ItemType itemType = g_items.getItemType(id);
				if (itemType.id != 0) {
					loadFromSpriteId(itemType.clientID);
					if (image.IsOk()) {
						spriteId = itemType.clientID;
						spriteSource = true;
					}
				}
			}
		} else {
			loadFromSpriteId(id);
			if (image.IsOk()) {
				spriteId = id;
				spriteSource = true;
			}
		}
	}

	LuaImage::LuaImage(const LuaImage& other) :
		image(other.image.IsOk() ? other.image.Copy() : wxImage()),
		filePath(other.filePath),
		spriteId(other.spriteId),
		spriteSource(other.spriteSource) {
	}

	LuaImage& LuaImage::operator=(const LuaImage& other) {
		if (this != &other) {
			image = other.image.IsOk() ? other.image.Copy() : wxImage();
			filePath = other.filePath;
			spriteId = other.spriteId;
			spriteSource = other.spriteSource;
		}
		return *this;
	}

	LuaImage::~LuaImage() {
		// wxImage handles its own cleanup
	}

	LuaImage LuaImage::loadFromFile(const std::string& path) {
		return LuaImage(path);
	}

	LuaImage LuaImage::loadFromItemSprite(int itemId) {
		return LuaImage(itemId, true);
	}

	LuaImage LuaImage::loadFromSprite(int spriteId) {
		return LuaImage(spriteId, false);
	}

	// Helper to reliably get sprite ID from item ID, handling client ID mapping
	int getItemSpriteId(int itemId) {
		if (!g_items.typeExists(itemId)) {
			return 0;
		}
		ItemType itemType = g_items.getItemType(itemId);
		return itemType.clientID;
	}

	void LuaImage::loadFromSpriteId(int id) {
		Sprite* sprite = g_gui.gfx.getSprite(id);
		if (!sprite) {
			return;
		}

		GameSprite* gameSprite = dynamic_cast<GameSprite*>(sprite);
		if (gameSprite && gameSprite->width > 0 && gameSprite->height > 0) {
			// Calculate full sprite size (can be larger than 32x32 for multi-tile sprites)
			int spriteWidth = gameSprite->width * 32;
			int spriteHeight = gameSprite->height * 32;

			// Create image with alpha channel
			image.Create(spriteWidth, spriteHeight);
			image.InitAlpha();

			// Fill with transparent background
			unsigned char* imgData = image.GetData();
			unsigned char* alphaData = image.GetAlpha();
			memset(imgData, 0, spriteWidth * spriteHeight * 3);
			memset(alphaData, 0, spriteWidth * spriteHeight); // Fully transparent

			// Get sprite data for each part
			for (int y = 0; y < gameSprite->height; ++y) {
				for (int x = 0; x < gameSprite->width; ++x) {
					size_t spriteIndex = gameSprite->getIndex(x, y, 0, 0, 0, 0, 0);
					if (spriteIndex < gameSprite->spriteList.size()) {
						auto* normalImage = gameSprite->spriteList[spriteIndex];
						if (normalImage) {
							std::unique_ptr<uint8_t[]> rgbaData = normalImage->getRGBAData();
							if (rgbaData) {
								// Copy pixel data to the correct position
								int destX = (gameSprite->width - 1 - x) * 32;
								int destY = (gameSprite->height - 1 - y) * 32;

								for (int py = 0; py < 32; ++py) {
									for (int px = 0; px < 32; ++px) {
										int srcIdx = (py * 32 + px) * 4;
										int destIdx = (destY + py) * spriteWidth + (destX + px);

										// Only copy non-transparent pixels
										uint8_t alpha = rgbaData[srcIdx + 3];
										if (alpha > 0) {
											imgData[destIdx * 3 + 0] = rgbaData[srcIdx + 0]; // R
											imgData[destIdx * 3 + 1] = rgbaData[srcIdx + 1]; // G
											imgData[destIdx * 3 + 2] = rgbaData[srcIdx + 2]; // B
											alphaData[destIdx] = alpha;
										}
									}
								}
							}
						}
					}
				}
			}
			return;
		}

		// Fallback: use DC-based rendering
		wxBitmap bmp(32, 32, 32);
		wxMemoryDC dc(bmp);
		dc.SetBackground(*wxWHITE_BRUSH);
		dc.Clear();
		SpriteIconService::DrawTo(sprite, &dc, SPRITE_SIZE_32x32, 0, 0, 32, 32);
		dc.SelectObject(wxNullBitmap);
		image = bmp.ConvertToImage();
	}

	int LuaImage::getWidth() const {
		return image.IsOk() ? image.GetWidth() : 0;
	}

	int LuaImage::getHeight() const {
		return image.IsOk() ? image.GetHeight() : 0;
	}

	bool LuaImage::isValid() const {
		return image.IsOk();
	}

	LuaImage LuaImage::resize(int width, int height, bool smooth) const {
		LuaImage result;
		if (image.IsOk() && width > 0 && height > 0) {
			wxImageResizeQuality quality = smooth ? wxIMAGE_QUALITY_HIGH : wxIMAGE_QUALITY_NEAREST;
			result.image = image.Scale(width, height, quality);
			// Do not inherit identity fields for resized images
			result.filePath = "";
			result.spriteId = 0;
			result.spriteSource = false;
		}
		return result;
	}

	LuaImage LuaImage::scale(double factor, bool smooth) const {
		if (factor <= 0 || !image.IsOk()) {
			return LuaImage();
		}
		int w = static_cast<int>(image.GetWidth() * factor);
		int h = static_cast<int>(image.GetHeight() * factor);

		LuaImage result = resize(w, h, smooth);
		// resize already cleared identity fields
		return result;
	}

	wxBitmap LuaImage::getBitmap() const {
		if (!image.IsOk()) {
			return wxNullBitmap;
		}
		return wxBitmap(image);
	}

	wxBitmap LuaImage::getBitmap(int width, int height, bool smooth) const {
		if (!image.IsOk() || width <= 0 || height <= 0) {
			return wxNullBitmap;
		}
		wxImageResizeQuality quality = smooth ? wxIMAGE_QUALITY_HIGH : wxIMAGE_QUALITY_NEAREST;
		wxImage scaled = image.Scale(width, height, quality);
		return wxBitmap(scaled);
	}

	// Composite actual SERVER ITEM appearances. Wide/tall sprites use Tibia's
	// bottom-right tile anchoring; x,y are tile offsets inside the preview.
	LuaImage LuaImage::composeItemGrid(int width, int height, sol::table entries) {
		if (width < 1 || height < 1 || width > 40 || height > 40) {
			throw sol::error("Preview dimensions must be between 1 and 40 SQM");
		}
		if (entries.size() > 320) {
			throw sol::error("Too many sprite placements for preview");
		}
		struct Placement {
			int itemId;
			int x;
			int y;
			int order;
		};
		std::vector<Placement> placements;
		placements.reserve(entries.size());
		int index = 0;
		for (auto &pair : entries) {
			if (!pair.second.is<sol::table>()) {
				throw sol::error("Each preview entry must be {id,x,y}");
			}
			sol::table e = pair.second.as<sol::table>();
			int id = e.get_or("id", 0);
			int x = e.get_or("x", -1);
			int y = e.get_or("y", -1);
			if (id < 1 || id > g_items.getMaxID() || !g_items.typeExists(id) ||
				x < 0 || y < 0 || x >= width || y >= height) {
				throw sol::error("Invalid item ID or preview position");
			}
			placements.push_back({id, x, y, index++});
		}
		std::stable_sort(placements.begin(), placements.end(),
			[](const Placement &a, const Placement &b) {
				if (a.y != b.y) return a.y < b.y;
				if (a.x != b.x) return a.x < b.x;
				return a.order < b.order;
			});

		const int outWidth = width * 32;
		const int outHeight = height * 32;
		LuaImage result;
		if (!result.image.Create(outWidth, outHeight)) {
			throw sol::error("Cannot allocate structure preview");
		}
		unsigned char* dst = result.image.GetData();
		for (int y = 0; y < outHeight; ++y) {
			for (int x = 0; x < outWidth; ++x) {
				int cell = ((x / 16) + (y / 16)) & 1;
				unsigned char base = cell ? 205 : 229;
				size_t offset = (static_cast<size_t>(y) * outWidth + x) * 3;
				dst[offset] = base;
				dst[offset + 1] = base;
				dst[offset + 2] = base;
			}
		}
		for (const auto &p : placements) {
			LuaImage sprite = LuaImage::loadFromItemSprite(p.itemId);
			if (!sprite.isValid()) continue;
			const wxImage &source = sprite.getWxImage();
			const int sw = source.GetWidth();
			const int sh = source.GetHeight();
			const unsigned char* rgb = source.GetData();
			const unsigned char* alpha = source.HasAlpha() ? source.GetAlpha() : nullptr;
			const int left = (p.x + 1) * 32 - sw;
			const int top = (p.y + 1) * 32 - sh;
			for (int sy = 0; sy < sh; ++sy) {
				int dy = top + sy;
				if (dy < 0 || dy >= outHeight) continue;
				for (int sx = 0; sx < sw; ++sx) {
					int dx = left + sx;
					if (dx < 0 || dx >= outWidth) continue;
					const size_t si = static_cast<size_t>(sy) * sw + sx;
					const int a = alpha ? alpha[si] : 255;
					if (a == 0) continue;
					const size_t di = (static_cast<size_t>(dy) * outWidth + dx) * 3;
					for (int c = 0; c < 3; ++c) {
						dst[di + c] = static_cast<unsigned char>(
							(rgb[si * 3 + c] * a + dst[di + c] * (255 - a) + 127) / 255
						);
					}
				}
			}
		}
		return result;
	}

	double LuaImage::edgeCost(int firstId, int secondId, const std::string &direction) {
		if (direction != "right" && direction != "down") {
			throw sol::error("Edge direction must be 'right' or 'down'");
		}
		if (firstId < 1 || secondId < 1 || firstId > g_items.getMaxID() ||
			secondId > g_items.getMaxID() ||
			!g_items.typeExists(firstId) || !g_items.typeExists(secondId)) {
			return -1.0;
		}
		LuaImage a = LuaImage::loadFromItemSprite(firstId);
		LuaImage b = LuaImage::loadFromItemSprite(secondId);
		if (!a.isValid() || !b.isValid() ||
			a.getWidth() != 32 || a.getHeight() != 32 ||
			b.getWidth() != 32 || b.getHeight() != 32) {
			return -1.0; // Do not match whole large sprites as separate SQMs.
		}
		const wxImage &ia = a.getWxImage();
		const wxImage &ib = b.getWxImage();
		const unsigned char* ra = ia.GetData();
		const unsigned char* rb = ib.GetData();
		const unsigned char* aa = ia.HasAlpha() ? ia.GetAlpha() : nullptr;
		const unsigned char* ab = ib.HasAlpha() ? ib.GetAlpha() : nullptr;
		double total = 0.0;
		int samples = 0;
		for (int k = 0; k < 32; ++k) {
			int ax = direction == "right" ? 31 : k;
			int ay = direction == "right" ? k : 31;
			int bx = direction == "right" ? 0 : k;
			int by = direction == "right" ? k : 0;
			int ai = ay * 32 + ax;
			int bi = by * 32 + bx;
			int alphaA = aa ? aa[ai] : 255;
			int alphaB = ab ? ab[bi] : 255;
			if (alphaA < 24 && alphaB < 24) continue;
			++samples;
			if (alphaA < 24 || alphaB < 24) {
				total += 0.8;
				continue;
			}
			int diff = 0;
			for (int c = 0; c < 3; ++c)
				diff += std::abs(static_cast<int>(ra[ai * 3 + c]) -
					static_cast<int>(rb[bi * 3 + c]));
			total += (static_cast<double>(diff) / 765.0) +
				(static_cast<double>(std::abs(alphaA - alphaB)) / 255.0) * 0.2;
		}
		if (samples < 6) return -1.0;
		return total / samples;
	}


	// Cache each sprite's four RGBA border signatures once, then compare
	// candidates in-memory. This permits up to 220 pieces without making
	// tens of thousands of separate sprite-rendering calls.
	sol::table LuaImage::autoArrange(sol::this_state ts, sol::table ids, int width, int height) {
		sol::state_view lua(ts);
		const int n = static_cast<int>(ids.size());
		if (width < 1 || height < 1 || width > 40 || height > 40 ||
			n < 1 || n > 220 || width * height != n) {
			throw sol::error("Edge arrangement expects a full grid of 1-220 tiles");
		}
		struct Signature {
			int id;
			bool valid = false;
			// top, right, bottom, left; RGBA per pixel
			std::array<std::array<std::array<unsigned char, 4>, 32>, 4> edge{};
		};
		std::vector<Signature> available;
		available.reserve(n);
		for (int i = 1; i <= n; ++i) {
			int id = ids.get_or(i, 0);
			if (id < 1 || id > g_items.getMaxID() || !g_items.typeExists(id)) {
				throw sol::error("Unknown server item ID in edge arrangement");
			}
			Signature signature;
			signature.id = id;
			LuaImage sprite = LuaImage::loadFromItemSprite(id);
			if (sprite.isValid() && sprite.getWidth() == 32 && sprite.getHeight() == 32) {
				const wxImage &pic = sprite.getWxImage();
				const unsigned char* rgb = pic.GetData();
				const unsigned char* alpha = pic.HasAlpha() ? pic.GetAlpha() : nullptr;
				for (int dir = 0; dir < 4; ++dir) {
					for (int k = 0; k < 32; ++k) {
						int x = dir == 1 ? 31 : dir == 3 ? 0 : k;
						int y = dir == 2 ? 31 : dir == 0 ? 0 : k;
						int p = y * 32 + x;
						for (int c = 0; c < 3; ++c)
							signature.edge[dir][k][c] = rgb[p * 3 + c];
						signature.edge[dir][k][3] = alpha ? alpha[p] : 255;
					}
				}
				signature.valid = true;
			}
			available.push_back(signature);
		}
		auto compare = [](const Signature &a, int sideA,
				const Signature &b, int sideB) -> double {
			if (!a.valid || !b.valid) return -1.0;
			double difference = 0.0;
			int active = 0;
			for (int k = 0; k < 32; ++k) {
				const auto &p = a.edge[sideA][k];
				const auto &q = b.edge[sideB][k];
				if (p[3] < 24 && q[3] < 24) continue;
				++active;
				if (p[3] < 24 || q[3] < 24) {
					difference += 0.8;
					continue;
				}
				double delta = 0.0;
				for (int c = 0; c < 3; ++c)
					delta += std::abs(static_cast<int>(p[c]) -
						static_cast<int>(q[c]));
				difference += (delta / 765.0) +
					std::abs(static_cast<int>(p[3]) - static_cast<int>(q[3])) / 1275.0;
			}
			return active < 6 ? -1.0 : difference / active;
		};

		std::vector<Signature> placed;
		placed.reserve(n);
		double totalCost = 0.0;
		int matchedEdges = 0;
		for (int idx = 0; idx < n; ++idx) {
			int x = idx % width;
			int y = idx / width;
			int chosen = 0;
			double best = std::numeric_limits<double>::infinity();
			for (int j = 0; j < static_cast<int>(available.size()); ++j) {
				double score = 0.0;
				int neighbours = 0;
				if (x > 0) {
					double cost = compare(placed[idx - 1], 1, available[j], 3);
					if (cost >= 0) { score += cost; ++neighbours; }
				}
				if (y > 0) {
					double cost = compare(placed[idx - width], 2, available[j], 0);
					if (cost >= 0) { score += cost; ++neighbours; }
				}
				if (neighbours > 0) {
					score = score / neighbours + (2 - neighbours) * 0.05;
					if (score < best) { best = score; chosen = j; }
				} else if (best == std::numeric_limits<double>::infinity()) {
					chosen = 0; // unchanged ID order if evidence is insufficient
				}
			}
			Signature selected = available[chosen];
			available.erase(available.begin() + chosen);
			if (x > 0) {
				double c = compare(placed[idx - 1], 1, selected, 3);
				if (c >= 0) { totalCost += c; ++matchedEdges; }
			}
			if (y > 0) {
				double c = compare(placed[idx - width], 2, selected, 0);
				if (c >= 0) { totalCost += c; ++matchedEdges; }
			}
			placed.push_back(selected);
		}
		sol::table result = lua.create_table();
		sol::table entries = lua.create_table(n, 0);
		int invalidSprites = 0;
		for (int i = 0; i < n; ++i) {
			sol::table piece = lua.create_table();
			piece["id"] = placed[i].id;
			piece["x"] = i % width;
			piece["y"] = i / width;
			entries[i + 1] = piece;
			if (!placed[i].valid) ++invalidSprites;
		}
		result["entries"] = entries;
		result["matchedEdges"] = matchedEdges;
		result["averageCost"] = matchedEdges > 0 ? totalCost / matchedEdges : -1.0;
		result["unsupportedSprites"] = invalidSprites;
		return result;
	}

	bool LuaImage::operator==(const LuaImage& other) const {
		if (spriteSource && other.spriteSource) {
			return spriteId == other.spriteId;
		}
		if (!spriteSource && !other.spriteSource) {
			return imagesHaveSamePixels(image, other.image);
		}
		return false;
	}

	void registerImage(sol::state& lua) {
		// Register LuaImage as "Image" usertype
		lua.new_usertype<LuaImage>(
			"Image",
			// Constructors
			sol::constructors<
				LuaImage(),
				LuaImage(const std::string&)>(),

			// Alternative constructor from table: Image{path = "..."} or Image{itemid = 100}
			sol::call_constructor, sol::factories(
									   // Default constructor
									   []() { return LuaImage(); },
									   // Path constructor
									   [](const std::string& path) { return LuaImage(path); },
									   // Table constructor
									   [](sol::table t) {
										   if (t["path"].valid()) {
											   return LuaImage::loadFromFile(t.get<std::string>("path"));
										   }
										   if (t["itemid"].valid()) {
											   return LuaImage::loadFromItemSprite(t.get<int>("itemid"));
										   }
										   if (t["spriteid"].valid()) {
											   return LuaImage::loadFromSprite(t.get<int>("spriteid"));
										   }
										   return LuaImage();
									   }
								   ),

			// Static factory methods
			"fromFile", &LuaImage::loadFromFile,
			"fromItemSprite", &LuaImage::loadFromItemSprite,
			"fromSprite", &LuaImage::loadFromSprite,
			"composeItems", &LuaImage::composeItemGrid,
			"edgeCost", &LuaImage::edgeCost,
			"autoArrange", &LuaImage::autoArrange,

			// Properties (read-only)
			"width", sol::property(&LuaImage::getWidth),
			"height", sol::property(&LuaImage::getHeight),
			"valid", sol::property(&LuaImage::isValid),
			"path", sol::property(&LuaImage::getPath),
			"spriteId", sol::property(&LuaImage::getSpriteId),
			"isFromSprite", sol::property(&LuaImage::isSpriteSource),

			// Methods
			"resize", [](const LuaImage& img, int w, int h, sol::optional<bool> smooth) { return img.resize(w, h, smooth.value_or(true)); },
			"scale", [](const LuaImage& img, double factor, sol::optional<bool> smooth) { return img.scale(factor, smooth.value_or(true)); },

			// Equality comparison
			sol::meta_function::equal_to, &LuaImage::operator==,

			// String representation
			sol::meta_function::to_string, [](const LuaImage& img) {
			if (!img.isValid()) {
				return std::string("Image(invalid)");
			}
			if (img.isSpriteSource()) {
				return "Image(sprite=" + std::to_string(img.getSpriteId()) +
					   ", " + std::to_string(img.getWidth()) + "x" + std::to_string(img.getHeight()) + ")";
			}
			return "Image(\"" + img.getPath() + "\", " +
				   std::to_string(img.getWidth()) + "x" + std::to_string(img.getHeight()) + ")"; }
		);
	}

} // namespace LuaAPI
