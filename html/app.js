const app = document.getElementById('app');
const tabletTitle = document.getElementById('tabletTitle');
const closeBtn = document.getElementById('closeBtn');
const levelLabel = document.getElementById('levelLabel');
const xpLabel = document.getElementById('xpLabel');
const xpFill = document.getElementById('xpFill');
const bonusLabel = document.getElementById('bonusLabel');
const dailyLabel = document.getElementById('dailyLabel');
const resetLabel = document.getElementById('resetLabel');
const walletLabel = document.getElementById('walletLabel');
const objectiveText = document.getElementById('objectiveText');
const questSteps = document.getElementById('questSteps');
const inventoryList = document.getElementById('inventoryList');
const loopsLabel = document.getElementById('loopsLabel');
const earnedLabel = document.getElementById('earnedLabel');
const collectCrop = document.getElementById('collectCrop');
const collectBtn = document.getElementById('collectBtn');
const recipeList = document.getElementById('recipeList');
const sellList = document.getElementById('sellList');
const fillAllBtn = document.getElementById('fillAllBtn');
const sellBtn = document.getElementById('sellBtn');
const waypointBtn = document.getElementById('waypointBtn');
const receiptModal = document.getElementById('receiptModal');
const receiptList = document.getElementById('receiptList');
const receiptTotal = document.getElementById('receiptTotal');
const receiptClose = document.getElementById('receiptClose');
const toastStack = document.getElementById('toastStack');
const progressOverlay = document.getElementById('progressOverlay');
const progressLabel = document.getElementById('progressLabel');
const progressFill = document.getElementById('progressFill');

const tabs = Array.from(document.querySelectorAll('.tab-btn'));
const tabContents = Array.from(document.querySelectorAll('.tab-content'));

const uiState = {
    visible: false,
    activeTab: 'collect',
    state: null,
    sellDraft: {}
};

function nui(action, payload = {}) {
    return fetch(`https://${GetParentResourceName()}/${action}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(payload)
    });
}

function formatCash(value) {
    const amount = Number(value) || 0;
    return `$${amount.toLocaleString()}`;
}

function setTab(tabKey) {
    uiState.activeTab = tabKey;
    tabs.forEach((tabButton) => {
        tabButton.classList.toggle('active', tabButton.dataset.tab === tabKey);
    });

    tabContents.forEach((content) => {
        content.classList.toggle('hidden', content.dataset.content !== tabKey);
    });
}

function renderQuest(state) {
    objectiveText.textContent = state.objective?.text || 'Open your tablet near a farm zone.';
    questSteps.innerHTML = '';

    (state.questSteps || []).forEach((step) => {
        const li = document.createElement('li');
        if (step.done) {
            li.classList.add('done');
        }

        const dot = document.createElement('span');
        dot.className = 'step-dot';

        const label = document.createElement('span');
        label.textContent = step.label || step.key;

        li.append(dot, label);
        questSteps.appendChild(li);
    });

    const waypointOn = !!state.preferences?.waypoint;
    waypointBtn.textContent = `Waypoint: ${waypointOn ? 'ON' : 'OFF'}`;
}

function renderXp(state) {
    levelLabel.textContent = `Level ${state.level || 1}`;
    xpLabel.textContent = `${state.xp || 0} XP`;
    xpFill.style.width = `${Math.max(0, Math.min(100, Number(state.levelProgressPct) || 0))}%`;
    bonusLabel.textContent = `Payout bonus: +${state.levelBonusPct || 0}%`;

    dailyLabel.textContent = `${state.daily?.actions || 0} / ${state.daily?.maxActions || 0}`;
    resetLabel.textContent = `Reset date: ${state.daily?.lastResetDate || '-'}`;

    walletLabel.textContent = formatCash(state.wallet || 0);
}

function renderInventory(state) {
    inventoryList.innerHTML = '';
    const order = state.itemOrder || Object.keys(state.inventory || {});

    order.forEach((itemKey) => {
        const label = state.itemLabels?.[itemKey] || itemKey;
        const amount = state.inventory?.[itemKey] || 0;
        const li = document.createElement('li');
        li.innerHTML = `<span>${label}</span><strong>${amount}</strong>`;
        inventoryList.appendChild(li);
    });

    loopsLabel.textContent = `Loops complete: ${state.stats?.loopsCompleted || 0}`;
    earnedLabel.textContent = `Total earned: ${formatCash(state.stats?.totalEarned || 0)}`;
}

function renderCollect(state) {
    const previous = collectCrop.value;
    collectCrop.innerHTML = '';

    Object.entries(state.crops || {}).forEach(([cropKey, crop]) => {
        const option = document.createElement('option');
        option.value = cropKey;
        option.textContent = crop.label || cropKey;
        collectCrop.appendChild(option);
    });

    if (previous && collectCrop.querySelector(`option[value="${previous}"]`)) {
        collectCrop.value = previous;
    }
}

function formatItemMap(map, labels) {
    return Object.entries(map || {})
        .map(([item, amount]) => `${amount}x ${labels?.[item] || item}`)
        .join(', ');
}

function renderRecipes(state) {
    recipeList.innerHTML = '';

    Object.values(state.recipes || {}).forEach((recipe) => {
        const row = document.createElement('div');
        row.className = 'recipe-row';

        const text = document.createElement('div');
        text.innerHTML = `
            <strong>${recipe.label}</strong>
            <div class="recipe-meta">Input: ${formatItemMap(recipe.inputs, state.itemLabels)}</div>
            <div class="recipe-meta">Output: ${formatItemMap(recipe.outputs, state.itemLabels)} | +${recipe.xp || 0} XP</div>
        `;

        const button = document.createElement('button');
        button.className = 'primary-btn';
        button.textContent = 'Process';
        button.addEventListener('click', () => {
            nui('process', { recipe: recipe.key });
        });

        row.append(text, button);
        recipeList.appendChild(row);
    });
}

function renderSell(state) {
    sellList.innerHTML = '';
    const order = state.itemOrder || [];

    order.forEach((itemKey) => {
        const amount = state.inventory?.[itemKey] || 0;
        const price = state.sellPrices?.[itemKey] || 0;
        const label = state.itemLabels?.[itemKey] || itemKey;

        const row = document.createElement('div');
        row.className = 'sell-row';

        const left = document.createElement('div');
        left.innerHTML = `
            <strong>${label}</strong>
            <div class="recipe-meta">Have: ${amount} | Price: ${formatCash(price)}</div>
        `;

        const quantity = document.createElement('input');
        quantity.type = 'number';
        quantity.className = 'quantity-input';
        quantity.min = '0';
        quantity.max = String(amount);
        quantity.value = String(Math.min(uiState.sellDraft[itemKey] || 0, amount));

        quantity.addEventListener('input', () => {
            const value = Math.max(0, Math.min(amount, Number(quantity.value) || 0));
            uiState.sellDraft[itemKey] = value;
            quantity.value = String(value);
        });

        row.append(left, quantity);
        sellList.appendChild(row);
    });
}

function renderState(state) {
    if (!state) {
        return;
    }

    renderXp(state);
    renderQuest(state);
    renderInventory(state);
    renderCollect(state);
    renderRecipes(state);
    renderSell(state);
}

function pushToast(type, text) {
    const toast = document.createElement('div');
    toast.className = `toast ${type || 'success'}`;
    toast.textContent = text || 'Farm update';
    toastStack.appendChild(toast);

    setTimeout(() => {
        toast.remove();
    }, 3200);
}

function showReceipt(receipt) {
    receiptList.innerHTML = '';

    (receipt?.items || []).forEach((line) => {
        const li = document.createElement('li');
        li.textContent = `${line.label} x${line.quantity} = ${formatCash(line.lineTotal)}`;
        receiptList.appendChild(li);
    });

    const paidTo = receipt?.paidToWallet ? 'farm wallet' : 'cash';
    receiptTotal.textContent = `Total ${formatCash(receipt?.totalPayout || 0)} (bonus +${receipt?.bonusPct || 0}%) paid to ${paidTo}.`;
    receiptModal.classList.remove('hidden');
}

function showProgress(show, label, percent) {
    progressOverlay.classList.toggle('hidden', !show);
    if (!show) {
        return;
    }

    progressLabel.textContent = label || 'Working...';
    progressFill.style.width = `${Math.max(0, Math.min(100, Number(percent) || 0))}%`;
}

window.addEventListener('message', (event) => {
    const payload = event.data || {};

    if (payload.action === 'open') {
        app.classList.remove('hidden');
        uiState.visible = true;
        tabletTitle.textContent = payload.title || 'Sunny Farm Tablet';
        setTab(payload.tab || uiState.activeTab);
        return;
    }

    if (payload.action === 'close') {
        uiState.visible = false;
        app.classList.add('hidden');
        showProgress(false);
        return;
    }

    if (payload.action === 'sync') {
        uiState.state = payload.state || null;
        renderState(uiState.state);
        return;
    }

    if (payload.action === 'toast') {
        pushToast(payload.toast?.type, payload.toast?.text);
        return;
    }

    if (payload.action === 'receipt') {
        showReceipt(payload.receipt);
        return;
    }

    if (payload.action === 'levelUp') {
        levelLabel.classList.add('level-pop');
        pushToast('success', `Level up! You are now level ${payload.data?.level || '?'}.`);
        setTimeout(() => levelLabel.classList.remove('level-pop'), 700);
        return;
    }

    if (payload.action === 'progress') {
        showProgress(payload.show, payload.label, payload.percent);
    }
});

closeBtn.addEventListener('click', () => nui('close'));
receiptClose.addEventListener('click', () => {
    receiptModal.classList.add('hidden');
});

collectBtn.addEventListener('click', () => {
    nui('collect', { crop: collectCrop.value });
});

sellBtn.addEventListener('click', () => {
    nui('sell', { items: uiState.sellDraft });
});

fillAllBtn.addEventListener('click', () => {
    const state = uiState.state;
    if (!state) {
        return;
    }

    (state.itemOrder || []).forEach((itemKey) => {
        uiState.sellDraft[itemKey] = state.inventory?.[itemKey] || 0;
    });

    renderSell(state);
});

waypointBtn.addEventListener('click', () => {
    const current = !!uiState.state?.preferences?.waypoint;
    nui('setWaypoint', { enabled: !current });
});

tabs.forEach((tabButton) => {
    tabButton.addEventListener('click', () => {
        setTab(tabButton.dataset.tab);
    });
});

document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && uiState.visible) {
        nui('close');
    }
});

nui('requestSync');