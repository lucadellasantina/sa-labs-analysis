classdef DataCuratorPresenter < appbox.Presenter
    
    properties (Access = protected)
        offlineAnalysisManager
    end
    
    properties (Access = private)
        log
        settings
        uuidToNode
    end
    
    properties (Constant)
        DATA_CURATOR_PLOTS = 'sa_labs.analysis.data_curator.plots'
        PRE_PROCESSOR_FUNCTIONS = 'sa_labs.analysis.data_curator.pre_processor'
    end
    
    
    methods
        function obj = DataCuratorPresenter(offlineAnalysisManager, view)
            import sa_labs.analysis.*;
            if nargin < 2
                view = ui.views.DataCuratorView();
            end
            obj = obj@appbox.Presenter(view);
            obj.offlineAnalysisManager = offlineAnalysisManager;
            obj.settings = ui.settings.DataCuratorSettings();
            obj.log = logging.getLogger(app.Constants.ANALYSIS_LOGGER);
            obj.uuidToNode = containers.Map();
        end
    end
    
    methods (Access = protected)
        
        function willGo(obj)
            obj.populateAvailablePlots();
            obj.populateAvailablePreProcessors();
            obj.populatePreProcessorParameters();
            obj.populateCellDataFilters();
            try
                obj.loadSettings();
            catch x
                obj.log.debug(['Failed to load presenter settings: ' x.message]);
            end
            obj.updateStateOfControls();
        end
        
        function willStop(obj)
            try
                obj.saveSettings();
            catch x
                obj.log.debug(['Failed to save presenter settings: ' x.message]);
            end
        end
        
        function bind(obj)
            bind@appbox.Presenter(obj);
            
            v = obj.view;
            obj.addListener(v, 'LoadH5File', @obj.onViewLoadH5File);
            obj.addListener(v, 'ReParse', @obj.onViewReParse);
            obj.addListener(v, 'SelectedNodes', @obj.onViewSelectedNodes).Recursive = true;
            obj.addListener(v, 'SelectedDevices', @obj.onViewSelectedDevices);
            obj.addListener(v, 'SelectedPlots', @obj.onViewSelectedPlots);
            obj.addListener(v, 'SelectedPreProcessor', @obj.onViewSelectedPreProcessor);
            obj.addListener(v, 'ExecutePreProcessor', @obj.onViewExecutePreProcessor);
            obj.addListener(v, 'SelectedFilterProperty', @obj.onViewSelectedFilterProperty);
            obj.addListener(v, 'SelectedFilterRow', @obj.onViewSelectedFilterRow);
            obj.addListener(v, 'ExecuteFilter', @obj.onViewExecuteFilter);
            obj.addListener(v, 'AddDeleteTag', @obj.onViewAddDeleteTag);
            obj.addListener(v, 'DeleteEntity', @obj.onViewSelectedDeleteEntity);
        end
    end
    
    methods (Access = private)
        
        function populateAvailablePlots(obj)
            plots = {meta.package.fromName(obj.DATA_CURATOR_PLOTS).FunctionList.Name};
            functionNames = {};
            for plot = each(plots)
                functionNames{end + 1} = [obj.DATA_CURATOR_PLOTS '.'  plot]; %#ok
            end
            obj.view.setAvailablePlots(plots, functionNames);
        end
        
        function populateAvailablePreProcessors(obj)
            packages = {meta.package.fromName(obj.PRE_PROCESSOR_FUNCTIONS).PackageList.Name};
            functionNames = {''};
            preProcessors= {'none'};
            for package = each(packages)
                names = {meta.package.fromName(package).FunctionList.Name};
                for name = each(names)
                    functionNames{end + 1} = [package '.' name]; %#ok
                end
                preProcessors = [preProcessors names{:}];
            end
            obj.view.setAvailablePreProcessorFunctions(preProcessors, functionNames);
            
        end
        
        function populateCellDataFilters(obj)
            filters = obj.offlineAnalysisManager.getCellDataFilters();
            if ~ isempty(filters)
                obj.view.loadCellDataFilters({filters.name});
            end
        end
        
        function onViewLoadH5File(obj, ~, ~)
            
            pattern = obj.view.getH5FileLocation();
            if strcmp(pattern, obj.view.getExperimentName())
                return
            end
            obj.updatePlotPanel();
            cellDataArray = obj.offlineAnalysisManager.getParsedCellData(pattern);
            obj.view.setExperimentNode(pattern, cellDataArray);
            obj.populateEntityTree(cellDataArray);
            obj.populateFilterDetails(cellDataArray);
        end
        
        function populateEntityTree(obj, cellDataArray)
           
            for cellData = each(cellDataArray)
                obj.addCellDataNode(cellData);
            end
            obj.view.expandNode(obj.view.getCellFolderNode());
            enabled = numel(cellData) > 0;
            obj.view.enableAvailablePlots(enabled);
            obj.view.enableAvailablePreProcessorFunctions(enabled);
        end
        
        function addCellDataNode(obj, cellData)
            parent = obj.view.getCellFolderNode();
            n = obj.view.addCellDataNode(parent, cellData.recordingLabel, cellData);
            obj.uuidToNode(cellData.uuid) = n;
            
            for epoch = each(cellData.epochs)
                obj.addEpochDataNode(epoch);
            end
        end
        
        function addEpochDataNode(obj, epoch)
            parent = obj.uuidToNode(epoch.parentCell.uuid);
            epochIndex = num2str(epoch.get('epochNum'));
            [h, m, s] = hms(epoch.get('epochTime'));
            h5EpochNumber = epoch.get('h5EpochNumber');
            
            name = strcat('(', epochIndex, ')');
            if ~ isempty(h5EpochNumber)
                strcat(name, '-(h5epochNumber=', num2str(h5EpochNumber) ,')');
            end
            name = strcat(name, '-', num2str(h), ':', num2str(m), ':', num2str(s));
            n = obj.view.addEpochDataNode(parent, name, epoch);
            obj.uuidToNode(epoch.uuid) = n;
        end
        
        function populateFilterDetails(obj, cellDataArray)
            if isempty(cellDataArray)
                return
            end
            cellNames = {cellDataArray.recordingLabel};
            obj.view.setAvailableCellNames(cellNames);
            obj.populateFilterProperties();
        end
        
        function populateFilterProperties(obj)
            cellData = obj.getFilteredCellData();
            properties = cellData.getEpochKeysetUnion();
            obj.view.setFilterProperty(properties);
            obj.view.enableFilters(numel(cellData) == 1);
        end
        
        function onViewSelectedDevices(obj, ~, ~)
            entitiyMap = obj.getSelectedEntityMap();
            obj.preProcessEntityMap(entitiyMap);
            obj.plotEntityMap(entitiyMap);
            obj.populateDetailsForEntityMap(entitiyMap);
        end
        
        function onViewSelectedPlots(obj, ~, ~)
            obj.updatePlotPanel();
            entitiyMap = obj.getSelectedEntityMap();
            obj.plotEntityMap(entitiyMap);
        end
        
        function updatePlotPanel(obj)
            selectedPlots = obj.view.getSelectedPlots();
            obj.view.addPlotToPanelTab(selectedPlots);
            unSelectedplots = obj.view.getUnSelectedPlots();
            obj.view.removePlotFromPanelTab(unSelectedplots);
            
            titles = {};
            for plot = each(selectedPlots)
                parsedName = strsplit(plot, '.');
                titles{end +1} = parsedName{end}; %#ok
            end
            obj.view.setPlotPannelTitles(titles)
        end
        
        function onViewSelectedPreProcessor(obj, ~, ~)
            entities = obj.getSelectedEpoch();
            if ~ isempty(entities) && numel(entities) == 1
                obj.updatePreProcessorParameters(entities);
            else
                obj.populatePreProcessorParameters();
            end
        end
        
        function populatePreProcessorParameters(obj)
            
            functionNames = obj.view.getSelectedPreProcessorFunction();
            fields = sa_labs.analysis.ui.util.helpdocToFields(functionNames);
            if ~ isempty(fields)
                obj.view.setPreProcessorParameters(fields);
                obj.view.enablePreProcessorPropertyGrid('on');
            end
        end
        
        function onViewExecutePreProcessor(obj, ~, ~)
            entitiyMap = obj.getSelectedEntityMap();
            obj.processSelectedEntity(entitiyMap);
        end
        
        function cellData = getFilteredCellData(obj)
            cellName = obj.view.getSelectedCellName();
            cellDataArray = obj.view.getExperimentData();
            cellData = linq(cellDataArray).where(@(data) strcmp(data.recordingLabel, cellName)).first();
        end
        
        function onViewSelectedFilterProperty(obj, ~, uiEventData)
            indices = uiEventData.data.Indices;
            row = indices(1);
            property = obj.view.getSelectedFilterProperty(row);
            obj.populateFilterValueSuggestion(property);
        end
        
        function onViewSelectedFilterRow(obj, ~, uiEventData)
            row = uiEventData.data.Indices;
            property = obj.view.getSelectedFilterProperty(row);
            obj.populateFilterValueSuggestion(property);
        end
        
        function populateFilterValueSuggestion(obj, property)
            if isempty(property)
                return
            end
            values = obj.getFilteredCellData().getEpochValues(property);
            suggestedValues = {''};
            if ~ isempty(values)
                suggestedValues = linq(values).select(@(x) cellstr(num2str(x))).distinct().toList();
            end
            
            type = 'numeric';
            if iscellstr(values)
                type = 'string';
            end
            obj.view.setFilterValueSuggestion(type, suggestedValues);
        end
        
        function onViewExecuteFilter(obj, ~, ~)
            import sa_labs.analysis.entity.*;
            
            cellData = obj.getFilteredCellData();
            query = linq(1 : numel(cellData.epochs))...
                .select(@(index) struct(...
                'index', index,...
                'epoch', cellData.epochs(index)));
            
            filterRows = obj.view.getFilterRows();
            
            for row = each(filterRows)
                query = query.where(@(struct) row.predicate(struct.epoch));
            end
            
            filteredStruct = query.toArray();
            for structure = each(filteredStruct)
                structure.epoch.filtered = true;
            end
            enabled = numel(filteredStruct) > 0;
            obj.view.enableAddAndDeleteParameters(enabled);
            
            if enabled
                [p, v] = cellData.getUniqueParamValues([filteredStruct.index]);
                result = KeyValueEntity(containers.Map(p, v));
            else
                result = 'No matching records found !';
            end
            obj.view.setConsoleText(result);
        end
        
        function onViewSelectedNodes(obj, ~, ~)
            tic
            entitiyMap = obj.getSelectedEntityMap();
            obj.populateDevicesForCell(entitiyMap);
            obj.processSelectedEntity(entitiyMap);
            obj.view.update();
            elapsedTime = toc;
            obj.log.info(['selected node processing time: ' num2str(elapsedTime)]);
        end
        
        function processSelectedEntity(obj, entitiyMap)
            obj.preProcessEntityMap(entitiyMap);
            obj.plotEntityMap(entitiyMap);
            obj.populateDetailsForEntityMap(entitiyMap);
            obj.view.update();
        end
        
        function populateDevicesForCell(obj, entitiyMap)
            cellDataArray = obj.getSelectedCell(entitiyMap);
            
            if isempty(cellDataArray)
                return
            end
            devices = linq(cellDataArray).selectMany(@(d) d.getEpochValues('devices')).distinct().toList();
            obj.view.setAvailableDevices(devices, devices);
            obj.view.enableSelectDevices(numel(devices) > 0);
        end
        
        function entitiyMap = getSelectedEntityMap(obj)
            import sa_labs.analysis.*;
            nodes = obj.view.getSelectedNodes();
            entitiyMap = containers.Map('KeyType', 'char', 'ValueType', 'any');
            
            for node = each(nodes)
                entity = obj.view.getNodeEntity(node);
                type = obj.view.getNodeType(node);
                if ~ isempty(entity)
                    entitiyMap = util.collections.addToMap(entitiyMap, char(type), entity);
                end
            end
        end
        
        function populateDetailsForEntityMap(obj, entitiyMap)
            values = entitiyMap.values;
            entities = [values{:}];
            isValidEntity = ~ isempty(entities) && numel(entities) == 1;
            
            if isValidEntity
                fields = uiextras.jide.PropertyGridField.GenerateFromMap(entities(1).attributes);
            else
                fields = uiextras.jide.PropertyGridField.empty(0, 1);
            end
            obj.view.setParameterPropertyGrid(fields);
            obj.view.enableAddAndDeleteParameter(isValidEntity);
        end
        
        function preProcessEntityMap(obj, entitiyMap)
            import sa_labs.analysis.ui.views.EntityNodeType;

            entities = obj.getSelectedCell(entitiyMap);
            if ~ isempty(entities)
                preProcesorHandles = obj.getPreProcessorHandle(char(EntityNodeType.CELLS));
                obj.offlineAnalysisManager.preProcessCellData(entities, preProcesorHandles);
            end

            entities = obj.getSelectedEpoch(entitiyMap);
            if ~ isempty(entities)
                obj.updatePreProcessorParameters(entities);
                preProcesorHandles = obj.getPreProcessorHandle(char(EntityNodeType.EPOCH));
                obj.offlineAnalysisManager.preProcessEpochData(entities, preProcesorHandles);
            end
        end

        function preProcesorHandles = getPreProcessorHandle(obj, type)

            preProcesors = obj.view.getSelectedPreProcessorFunction();
            preProcesors = linq(preProcesors).where(@(p) any(strfind(lower(p), lower(type)))).toList();
            preProcesorHandles = cell(1, numel(preProcesors));
            
            for i = 1 : numel(preProcesors)
                preProcessor = preProcesors{i};
                parameters = obj.view.getPreprocessorFunctionParameters(preProcessor);
                functionDelegate = getDelegate(preProcessor);
                preProcesorHandles{i} = @(data) functionDelegate(data, parameters);
            end
            
            function f = getDelegate(preProcessor)
                f = str2func(strcat('@(data, parameters) ', preProcessor, '(data, parameters)'));
                obj.log.info(['Executing ' func2str(f)])
            end
        end
        
        function updatePreProcessorParameters(obj, entity)
           
            if isempty(entity) || numel(entity) > 1
               return
            end

            import uiextras.jide.*;
            functionNames = obj.view.getSelectedPreProcessorFunction();
            defaultFields = sa_labs.analysis.ui.util.helpdocToFields(functionNames);
            fields = obj.view.getPreProcessorParameterPropertyGrid();
            devices = obj.view.getSelectedDevices();
            
            for i = 1 : numel(defaultFields)
                
                defaultField = defaultFields(i);
                oldField = fields.FindByName(defaultField.Name);
                
                if isFunctionHandle(defaultField.Value)
                    func = str2func(defaultField.Value);
                    values = func(entity, devices);
                    trueIndex = true(size(values));
                    
                    newField = PropertyGridField(defaultField.Name, trueIndex,...
                        'Type', PropertyType('logical', 'row', values));
                    newField.Category = defaultField.Category;
                    newField.DisplayName = defaultField.DisplayName;
                    defaultFields(i) = newField;
                    
                elseif ~ isempty(oldField)
                    defaultFields(i).Value = oldField.Value;
                end
            end
            
            if ~ isempty(defaultFields)
                obj.view.setPreProcessorParameters(defaultFields);
            end
            
            function tf = isFunctionHandle(value)
                tf = ischar(value) && ~ isempty((strfind(value, '@')) == 1);
            end
        end
        
        function plotEntityMap(obj, entitiyMap)
            import sa_labs.analysis.ui.views.EntityNodeType;
            key = char(EntityNodeType.EPOCH);
            
            if isempty(entitiyMap) || ~ isKey(entitiyMap, key)
                return
            end
            entities = entitiyMap(key);
            plots = obj.view.getSelectedPlots();
            devices = obj.view.getSelectedDevices();
            
            for i = 1 : numel(plots)
                plot = plots{i};
                functionDelegate = str2func(strcat('@(data, devices, axes) ', plot, '(data, devices, axes)'));
                try
                    functionDelegate(entities, devices, obj.view.getAxes(plot));
                catch exception
                    obj.view.showMessage(exception.message, 'Error');
                end
            end
        end
        
        function updateStateOfControls(obj)
        end
        
        function loadSettings(obj)
            if ~isempty(obj.settings.viewPosition)
                obj.view.position = obj.settings.viewPosition;
            end
        end
        
        function saveSettings(obj)
            obj.settings.viewPosition = obj.view.position;
            obj.settings.save();
        end
        
        function entities = getSelectedEpoch(obj, entitiyMap)
            import sa_labs.analysis.ui.views.EntityNodeType;
            
            if nargin < 2
                entitiyMap = obj.getSelectedEntityMap();
            end
            entities = [];
            key = char(EntityNodeType.EPOCH);
            if ~ isKey(entitiyMap, key)
                return
            end
            entities = entitiyMap(key);
            if isempty(entities)
                return
            end
        end
        
        function entities = getSelectedCell(obj, entitiyMap)
            import sa_labs.analysis.ui.views.EntityNodeType;
            
            if nargin < 2
                entitiyMap = obj.getSelectedEntityMap();
            end
            entities = [];
            key = char(EntityNodeType.CELLS);
            
            if isKey(entitiyMap, key)
                entities = entitiyMap(key);
            end
        end
        
        function onViewAddDeleteTag(obj, ~, ~)
            epochs = obj.getSelectedEpoch();
            for epoch = each(epochs)
                epoch.excluded = true;
                node = obj.uuidToNode(epoch.uuid);
                name = obj.view.getNodeName(node);
                obj.view.setNodeName(node, strcat('To delete-', name));
            end
        end
        
        function onViewSelectedDeleteEntity(obj, ~, ~)
            obj.deleteSelectedEntity();
        end
        
        function deleteSelectedEntity(obj)
            node = obj.view.getCellFolderNode();
            obj.view.collapseNode(node);
            cellDatas = obj.view.getExperimentData();
            
            result = obj.view.showMessage( ...
                'Are you sure you want to delete Tagged Epochs ?', 'Delete Entity', ...
                'button1', 'Cancel', ...
                'button2', 'Delete', ...
                'width', 300);
            if ~strcmp(result, 'Delete')
                return;
            end
            updatedCellDatas = obj.offlineAnalysisManager.deleteEpochFromCells(cellDatas);
            
            for updateCellData = each(updatedCellDatas)
                node = obj.uuidToNode(updateCellData.uuid);
                obj.view.removeNode(node);
            end
            obj.populateEntityTree(updatedCellDatas);
        end

    end
    
end