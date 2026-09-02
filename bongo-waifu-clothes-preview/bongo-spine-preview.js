(function () {
  "use strict";

  const atlasPath = "/spine-assets/BaseBody.atlas";
  const skeletonPath = "/spine-assets/BaseBody.skel";
  const candidatePagesByType = {
    SkinTone: ["BaseBody_3.png"],
    IntimateParts: ["BaseBody_4.png"],
    PubicAndGenital: ["BaseBody_11.png"],
    Hair: ["BaseBody_9.png", "BaseBody_10.png"],
    Top: ["BaseBody_14.png"],
    Bottom: ["BaseBody_5.png", "BaseBody_6.png"],
    Underwear: ["BaseBody_15.png"],
    Socks: ["BaseBody_13.png"],
    Shoes: ["BaseBody_12.png"],
    Dick: ["BaseBody_7.png"],
  };

  function loadImage(url) {
    return new Promise((resolve, reject) => {
      const image = new Image();
      image.decoding = "async";
      image.onload = () => resolve(image);
      image.onerror = () => reject(new Error(`Não foi possível abrir ${url}.`));
      image.src = url;
    });
  }

  class BongoSpinePreview {
    constructor(container, options = {}) {
      this.container = typeof container === "string" ? document.querySelector(container) : container;
      this.onState = typeof options.onState === "function" ? options.onState : () => {};
      this.onAnimations = typeof options.onAnimations === "function" ? options.onAnimations : () => {};
      this.onAnimation = typeof options.onAnimation === "function" ? options.onAnimation : () => {};
      this.player = null;
      this.atlas = null;
      this.pageByName = new Map();
      this.originalTextureByPage = new Map();
      this.customTextureByItem = new Map();
      this.assignedItemByPage = new Map();
      this.loadingImageByItem = new Map();
      this.lookVersion = 0;
      this.pendingLook = {
        items: [],
        animations: { action: "Idle", level: "Level_0", stain: "body_stain_00" },
        options: {},
      };
      this.currentItems = [];
      this.currentAnimation = "Idle";
      this.currentAnimations = { action: "Idle", level: "Level_0", stain: "body_stain_00" };
      this.sequenceVersion = 0;
      this.gameState = "Idle";
      this.love = 0;
      this.excitement = 0;
      this.orgasm = false;
      this.orgasmCount = 0;
      this.stateTime = 0;
      this.actionElapsed = 0;
      this.actionThreshold = 0.15;
      this.dirtiness = 0;
      this.disableMassagerIdle = Boolean(options.disableMassagerIdle);
      this.simulationFrame = 0;
      this.lastSimulationAt = 0;
      this.ready = false;
      this.failed = false;
      this.readyPromise = new Promise((resolve, reject) => {
        this.resolveReady = resolve;
        this.rejectReady = reject;
      });
    }

    initialize() {
      if (!this.container) {
        const error = new Error("A área da animação não foi encontrada.");
        this.failed = true;
        this.rejectReady(error);
        return this.readyPromise;
      }
      if (!window.spine?.SpinePlayer) {
        const error = new Error("O runtime Spine 4.2 não foi carregado.");
        this.failed = true;
        this.rejectReady(error);
        return this.readyPromise;
      }

      this.onState("loading");
      this.player = new window.spine.SpinePlayer(this.container, {
        atlas: atlasPath,
        skeleton: skeletonPath,
        animation: "Idle",
        alpha: true,
        backgroundColor: "00000000",
        fullScreenBackgroundColor: "211a2bff",
        // Spine's multiply layers require premultiplied texture pixels. The
        // Unity PNGs are straight-alpha, so they are converted during upload.
        premultipliedAlpha: true,
        showControls: false,
        showLoading: false,
        interactive: false,
        mipmaps: false,
        defaultMix: 0.2,
        viewport: {
          // The automatic Spine bounds include huge transparent regions from the
          // toy/effect atlas pages. This is the fixed in-game character frame;
          // every attachment is still rendered and only the camera is cropped.
          x: -470,
          y: 600,
          width: 940,
          height: 1000,
          padLeft: "2%",
          padRight: "2%",
          padTop: "2%",
          padBottom: "2%",
          transitionTime: 0.12,
        },
        success: (player) => this.handleReady(player),
        error: (_player, message) => this.handleError(new Error(message)),
        updateWorldTransform: (player) => {
          player.skeleton.updateWorldTransform(window.spine.Physics.update);
        },
      });
      const gl = this.player.context.gl;
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
      return this.readyPromise;
    }

    handleReady(player) {
      try {
        this.atlas = player.assetManager.require(atlasPath);
        this.atlas.pages.forEach((page) => {
          this.pageByName.set(page.name, page);
          this.originalTextureByPage.set(page.name, page.texture);
        });
        this.originalDefaultSkin = player.skeleton.data.defaultSkin;
        this.onAnimations(player.skeleton.data.animations.map((animation) => ({
          name: animation.name,
          duration: animation.duration,
        })));
        this.configureGameMixes();
        this.ready = true;
        this.resolveReady(this);
        this.onState("ready");
        this.startGameSimulation();
        const pending = this.pendingLook;
        this.applyLook(pending.items, pending.animations, pending.options).catch((error) => this.handleError(error));
      } catch (error) {
        this.handleError(error);
      }
    }

    handleError(error) {
      this.failed = true;
      if (!this.ready) this.rejectReady(error);
      this.onState("error", error);
    }

    pageNamesForItem(item) {
      if (item.texture_backed === false) return [];
      const candidates = candidatePagesByType[item.type] || [];
      const skin = this.player?.skeleton?.data?.findSkin(item.skin_name);
      if (!skin) return candidates.filter((name) => this.pageByName.has(name)).slice(0, 1);
      const usedPages = new Set();
      skin.getAttachments().forEach((entry) => {
        const pageName = entry.attachment?.region?.page?.name;
        if (pageName) usedPages.add(pageName);
      });
      const matching = candidates.filter((name) => usedPages.has(name) && this.pageByName.has(name));
      if (matching.length) return matching;
      return candidates.filter((name) => this.pageByName.has(name)).slice(0, 1);
    }

    getImage(item) {
      if (!this.loadingImageByItem.has(item.id)) {
        const request = loadImage(`/textures/${item.id}.png`).finally(() => this.loadingImageByItem.delete(item.id));
        this.loadingImageByItem.set(item.id, request);
      }
      return this.loadingImageByItem.get(item.id);
    }

    applySkin(items) {
      const skeleton = this.player.skeleton;
      const combined = new window.spine.Skin(`provador-${this.lookVersion}`);
      const added = new Set();
      if (this.originalDefaultSkin) {
        combined.addSkin(this.originalDefaultSkin);
        added.add(this.originalDefaultSkin.name);
      }
      items.forEach((item) => {
        if (!item.skin_name || added.has(item.skin_name)) return;
        const skin = skeleton.data.findSkin(item.skin_name);
        if (skin) {
          combined.addSkin(skin);
          added.add(item.skin_name);
        }
      });
      skeleton.setSkin(combined);
      skeleton.setSlotsToSetupPose();
    }

    animationLayer(name) {
      if (/^Level_\d+$/i.test(name)) return "level";
      if (/^body_stain_\d+$/i.test(name)) return "stain";
      return "action";
    }

    hasAnimation(name) {
      return Boolean(name && this.player?.skeleton?.data?.findAnimation(name));
    }

    configureGameMixes() {
      const data = this.player?.animationState?.data;
      if (!data) return;
      data.defaultMix = 0.2;
      const loops = ["Fuck_Loop_00", "Fuck_Loop_01", "Fuck_Loop_02", "Fuck_Loop_03"];
      const zeroMixPairs = [
        ["Idle_H", "Fuck_Loop_00"],
        ...loops.map((to) => ["Idle_H_End", to]),
        ...loops.slice(1).map((to) => ["Idle_H", to]),
        ...loops.flatMap((from) => loops.map((to) => [from, to])),
      ];
      zeroMixPairs.forEach(([from, to]) => {
        if (this.hasAnimation(from) && this.hasAnimation(to)) data.setMix(from, to, 0);
      });
    }

    hasToy() {
      return this.currentItems.some((item) => item.type === "Dick");
    }

    idleAnimation() {
      return this.hasAnimation("Idle") ? "Idle" : "Idle_NoDick";
    }

    emitAnimation(name, layer = this.animationLayer(name)) {
      this.currentAnimation = name;
      this.onAnimation({ name, layer, animations: { ...this.currentAnimations } });
    }

    setGameAnimation(track, name, loop, preventDuplicate = false, onComplete = null, mixDuration = -1, layer = null) {
      if (!this.hasAnimation(name)) return null;
      const state = this.player.animationState;
      const current = state.getCurrent(track);
      if (preventDuplicate && current?.animation?.name === name) return current;
      if (track > 0) {
        state.clearTrack(track);
        state.setEmptyAnimation(track, 0);
      }
      const entry = state.setAnimation(track, name, loop);
      if (mixDuration >= 0) entry.mixDuration = mixDuration;
      if (track > 0 && !loop) state.addEmptyAnimation(track, 0.1, 0);
      if (typeof onComplete === "function") {
        entry.listener = {
          complete: () => onComplete(),
        };
      }
      this.emitAnimation(name, layer || (track === 5 ? "level" : track === 6 ? "stain" : track === 0 ? "action" : "overlay"));
      return entry;
    }

    setOverlayAnimation(track, name, loop, onComplete = null, emptyMix = 0.3) {
      if (!this.hasAnimation(name)) return null;
      const state = this.player.animationState;
      const entry = state.setAnimation(track, name, loop);
      if (track > 0) {
        entry.mixBlend = window.spine.MixBlend.first;
        state.addEmptyAnimation(track, emptyMix, 0);
      }
      if (typeof onComplete === "function") entry.listener = { complete: () => onComplete() };
      this.emitAnimation(name, "overlay");
      return entry;
    }

    resetInteractionMeters() {
      this.love = 0;
      this.excitement = 0;
      this.orgasm = false;
      this.stateTime = 0;
      this.actionElapsed = 0;
      this.actionThreshold = 0.15;
      this.gameState = "Idle";
    }

    gameStateForAnimation(name) {
      if (name === "Fuck_Start") return "Fuck_Start";
      if (/^Fuck_Loop_\d+$/i.test(name)) return "Fuck_Loop";
      if (name === "Fuck_End") return "Fuck_End";
      if (name === "Idle_H") return "Idle_H";
      if (name === "Idle_H_End" || name === "Idle_H_End_NoDick") return "Idle_H_End";
      return "Idle";
    }

    startGameSimulation() {
      if (this.simulationFrame || typeof window.requestAnimationFrame !== "function") return;
      const preciseNow = window.performance?.now?.();
      this.lastSimulationAt = Number.isFinite(preciseNow) ? preciseNow : Date.now();
      const tick = (now) => {
        if (!this.ready) return;
        const elapsed = Math.min(Math.max((now - this.lastSimulationAt) / 1000, 0), 0.25);
        this.lastSimulationAt = now;
        this.updateGameSimulation(elapsed);
        this.simulationFrame = window.requestAnimationFrame(tick);
      };
      this.simulationFrame = window.requestAnimationFrame(tick);
    }

    updateGameLevel() {
      const level = this.excitement > 75 ? 3 : this.excitement > 50 ? 2 : this.excitement > 25 ? 1 : 0;
      const name = `Level_${level}`;
      if (!this.hasAnimation(name)) return;
      const current = this.player.animationState.getCurrent(5)?.animation?.name;
      if (this.currentAnimations.level === name && current === name) return;
      this.currentAnimations.level = name;
      this.setGameAnimation(5, name, true, true, null, -1, "level");
    }

    setBodyStain(level, instant = false) {
      const next = Math.min(Math.max(Number(level) || 0, 0), 10);
      const name = `body_stain_${String(next).padStart(2, "0")}`;
      if (!this.hasAnimation(name)) return false;
      const current = this.player.animationState.getCurrent(6)?.animation?.name;
      if (this.currentAnimations.stain === name && current === name) return false;
      const entry = this.player.animationState.setAnimation(6, name, true);
      entry.mixDuration = instant ? 0 : 1;
      this.dirtiness = next;
      this.currentAnimations.stain = name;
      this.emitAnimation(name, "stain");
      return true;
    }

    beginOrgasm() {
      if (this.orgasm) return;
      this.love = 100;
      this.orgasm = true;
      this.orgasmCount += 1;
      this.setBodyStain(Math.min(this.dirtiness + 1, 10), false);
    }

    updateControllerState(elapsed) {
      if (this.orgasm) {
        if (this.gameState !== "Fuck_End" && this.gameState !== "Idle_H_End") this.playFuckEnd();
        return;
      }
      if (this.love <= 0) {
        this.playIdle();
        return;
      }
      if (this.gameState !== "Idle_H" && this.gameState !== "Idle_H_End") return;
      this.stateTime += elapsed;
      if (this.stateTime > 20) {
        this.playIdle();
        this.stateTime = 0;
      }
    }

    updateGameSimulation(elapsed) {
      if (!elapsed) return;
      this.excitement = Math.min(Math.max(this.excitement - elapsed * 0.555555582, 0), 100);
      this.actionElapsed += elapsed;

      if (this.orgasm) {
        this.love -= elapsed * 15;
        if (this.love < 10) this.orgasm = false;
      } else {
        const normalizedLove = Math.min(Math.max(this.love / 100, 0), 1);
        const decay = 0.9160000086 + (2.746999979 - 0.9160000086) * normalizedLove;
        this.love -= elapsed * decay;
      }

      if (this.love < 0) this.love = 0;
      else if (this.love > 100) this.beginOrgasm();
      this.updateControllerState(elapsed);
      this.updateGameLevel();
    }

    gameClick() {
      if (!this.ready) return { accepted: false, reacted: false, reason: "not-ready" };
      if (!this.hasToy()) return { accepted: false, reacted: false, reason: "toy-required" };
      if (this.orgasm) return { accepted: false, reacted: false, reason: "orgasm", animation: this.currentAnimations.action };

      this.love += 0.75;
      this.excitement += 0.2;
      if (this.actionElapsed < this.actionThreshold) {
        return { accepted: true, reacted: false, reason: "cooldown", animation: this.currentAnimations.action, love: this.love };
      }

      let reacted = false;
      let animation = this.currentAnimations.action;
      if (this.gameState === "Idle" || this.gameState === "Idle_H_End") {
        animation = this.playFuckStart() || animation;
        this.actionElapsed = 0;
        this.actionThreshold = 0.5;
        this.stateTime = 0;
        reacted = true;
      } else if (this.gameState === "Idle_H" || this.gameState === "Fuck_Loop") {
        animation = this.playFuckLoop() || animation;
        this.actionElapsed = 0;
        this.actionThreshold = 0.05;
        this.stateTime = 0;
        reacted = Boolean(animation);
      }
      this.player.play();
      return {
        accepted: true,
        reacted,
        reason: reacted ? "animation" : "transition",
        animation,
        love: this.love,
      };
    }

    playConditionalIdle(stateName, primary, secondary) {
      const token = ++this.sequenceVersion;
      if (this.disableMassagerIdle && this.hasAnimation(secondary)) {
        this.currentAnimations.action = primary;
        this.setGameAnimation(0, primary, false, true, () => {
          if (token !== this.sequenceVersion || this.gameState !== stateName) return;
          this.currentAnimations.action = secondary;
          this.setGameAnimation(0, secondary, true, true, null, 0.3, "action");
        }, -1, "action");
      } else {
        this.currentAnimations.action = primary;
        this.setGameAnimation(0, primary, true, true, null, -1, "action");
      }
      return primary;
    }

    playIdle() {
      if (this.gameState === "Idle") return this.currentAnimations.action;
      this.gameState = "Idle";
      return this.playConditionalIdle("Idle", "Idle", "Idle_NoDick");
    }

    playExcitementEnd() {
      if (this.gameState === "Idle_H_End") return this.currentAnimations.action;
      this.gameState = "Idle_H_End";
      return this.playConditionalIdle("Idle_H_End", "Idle_H_End", "Idle_H_End_NoDick");
    }

    playHotIdle() {
      if (this.gameState === "Idle_H") return this.currentAnimations.action;
      this.gameState = "Idle_H";
      this.currentAnimations.action = "Idle_H";
      this.setGameAnimation(0, "Idle_H", true, true, null, -1, "action");
      return "Idle_H";
    }

    playFuckStart() {
      if (this.gameState === "Fuck_Start") return null;
      const token = ++this.sequenceVersion;
      this.gameState = "Fuck_Start";
      this.currentAnimations.action = "Fuck_Start";
      this.setGameAnimation(0, "Fuck_Start", false, true, () => {
        if (token !== this.sequenceVersion) return;
        this.playHotIdle();
      }, -1, "action");
      return "Fuck_Start";
    }

    playFuckLoop(name = null) {
      const loops = ["Fuck_Loop_00", "Fuck_Loop_01", "Fuck_Loop_02", "Fuck_Loop_03"].filter((entry) => this.hasAnimation(entry));
      if (!loops.length) return null;
      const selected = name && loops.includes(name) ? name : loops[Math.floor(Math.random() * loops.length)];
      this.gameState = "Fuck_Loop";
      this.setOverlayAnimation(1, selected, false, null, 0.3);
      return selected;
    }

    playFuckEnd() {
      if (this.gameState === "Fuck_End") return null;
      const token = ++this.sequenceVersion;
      this.excitement += 5;
      this.gameState = "Fuck_End";
      this.currentAnimations.action = "Fuck_End";
      this.setGameAnimation(0, "Fuck_End", false, true, () => {
        if (token !== this.sequenceVersion) return;
        this.playExcitementEnd();
      }, -1, "action");
      return "Fuck_End";
    }

    playChangeClothe() {
      this.setGameAnimation(2, "ChangeClothe", false, false, null, -1, "overlay");
      this.setOverlayAnimation(1, "ChangeClothe", false, null, 0.3);
      this.player.play();
      return "ChangeClothe";
    }

    setAnimation(name, loop = true) {
      if (!this.ready || !this.hasAnimation(name)) return false;
      const layer = this.animationLayer(name);
      if (layer === "level") {
        this.currentAnimations.level = name;
        this.setGameAnimation(5, name, true, true, null, -1, "level");
      } else if (layer === "stain") {
        const level = Number.parseInt(String(name).match(/\d+$/)?.[0] || "0", 10);
        this.setBodyStain(level, true);
      } else if (/^Fuck_Loop_\d+$/i.test(name)) {
        if (this.gameState !== "Idle_H" && this.gameState !== "Fuck_Loop") {
          this.gameState = "Idle_H";
          this.currentAnimations.action = "Idle_H";
          this.setGameAnimation(0, "Idle_H", true, true, null, -1, "action");
        }
        this.playFuckLoop(name);
      } else if (name === "Fuck_Start") {
        this.playFuckStart();
      } else if (name === "Fuck_End") {
        this.playFuckEnd();
      } else if (name === "ChangeClothe") {
        this.playChangeClothe();
      } else if (name === "Idle_H_End" || name === "Idle_H_End_NoDick") {
        this.sequenceVersion += 1;
        this.gameState = "Idle_H_End";
        this.currentAnimations.action = name;
        this.setGameAnimation(0, name, loop, true, null, -1, "action");
      } else {
        this.sequenceVersion += 1;
        this.gameState = this.gameStateForAnimation(name);
        this.currentAnimations.action = name;
        this.setGameAnimation(0, name, loop, true, null, -1, "action");
      }
      this.player.play();
      return true;
    }

    normalizeAnimationState(value) {
      if (typeof value === "string") {
        const layer = this.animationLayer(value);
        return { ...this.currentAnimations, [layer]: value };
      }
      return {
        action: value?.action || this.currentAnimations.action || this.idleAnimation(),
        level: value?.level || this.currentAnimations.level || "Level_0",
        stain: value?.stain || this.currentAnimations.stain || "body_stain_00",
      };
    }

    applyAnimationState(value) {
      const animations = this.normalizeAnimationState(value);
      let action = animations.action;
      if (action === "ChangeClothe") action = this.idleAnimation();
      if (!this.hasAnimation(action)) action = this.idleAnimation();
      this.setAnimation(action, !["ChangeClothe", "Fuck_Start", "Fuck_End", "Idle_H_End", "Idle_H_End_NoDick"].includes(action));
      if (this.hasAnimation(animations.level)) this.setAnimation(animations.level, true);
      if (this.hasAnimation(animations.stain)) this.setAnimation(animations.stain, true);
    }

    async applyLook(items, animations = this.currentAnimations, options = {}) {
      const normalizedItems = Array.isArray(items) ? items.filter(Boolean) : [];
      const normalizedAnimations = this.normalizeAnimationState(animations);
      const normalizedOptions = options && typeof options === "object" ? options : {};
      this.pendingLook = { items: normalizedItems, animations: normalizedAnimations, options: normalizedOptions };
      if (!this.ready) {
        if (this.failed) throw new Error("A prévia Spine não está disponível.");
        return false;
      }

      const version = ++this.lookVersion;
      this.onState("updating");
      const desiredPageItems = new Map();
      normalizedItems.forEach((item) => {
        this.pageNamesForItem(item).forEach((pageName) => desiredPageItems.set(pageName, item));
      });

      const desiredItems = [...new Map([...desiredPageItems.values()].map((item) => [item.id, item])).values()];
      const missingItems = desiredItems.filter((item) => !this.customTextureByItem.has(item.id));
      const images = await Promise.all(missingItems.map(async (item) => [item, await this.getImage(item)]));
      if (version !== this.lookVersion) return false;

      images.forEach(([item, image]) => {
        const texture = new window.spine.GLTexture(this.player.context, image, false);
        this.customTextureByItem.set(item.id, { texture, image });
      });

      [...this.assignedItemByPage].forEach(([pageName, itemId]) => {
        if (desiredPageItems.get(pageName)?.id === itemId) return;
        const page = this.pageByName.get(pageName);
        const original = this.originalTextureByPage.get(pageName);
        if (page && original) page.setTexture(original);
        this.assignedItemByPage.delete(pageName);
      });

      desiredPageItems.forEach((item, pageName) => {
        const page = this.pageByName.get(pageName);
        const custom = this.customTextureByItem.get(item.id);
        if (page && custom && this.assignedItemByPage.get(pageName) !== item.id) {
          page.setTexture(custom.texture);
          this.assignedItemByPage.set(pageName, item.id);
        }
      });

      const desiredItemIds = new Set(desiredItems.map((item) => item.id));
      [...this.customTextureByItem].forEach(([itemId, record]) => {
        if (desiredItemIds.has(itemId)) return;
        record.texture.dispose();
        this.customTextureByItem.delete(itemId);
      });

      const previousToyId = this.currentItems.find((item) => item.type === "Dick")?.id || 0;
      const nextToyId = normalizedItems.find((item) => item.type === "Dick")?.id || 0;
      this.currentItems = normalizedItems;
      if (previousToyId !== nextToyId) this.resetInteractionMeters();
      this.applySkin(normalizedItems);
      if (normalizedOptions.animateChange) {
        if (previousToyId !== nextToyId) this.setAnimation(this.idleAnimation(), true);
        this.playChangeClothe();
      } else {
        this.applyAnimationState(normalizedAnimations);
      }
      this.onState("ready");
      return true;
    }

    dispose() {
      this.ready = false;
      if (this.simulationFrame && typeof window.cancelAnimationFrame === "function") {
        window.cancelAnimationFrame(this.simulationFrame);
      }
      this.simulationFrame = 0;
      this.customTextureByItem.forEach((record) => record.texture.dispose());
      this.customTextureByItem.clear();
      this.player?.dispose();
    }
  }

  window.BongoSpinePreview = BongoSpinePreview;
})();
